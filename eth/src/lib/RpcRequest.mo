import Trie "mo:base/Trie";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Option "mo:base/Option";
import Minter "mo:icl/icETHMinter";
import Tools "mo:icl/Tools";

module{
    type AccountId = Blob;
    type Timestamp = Minter.Timestamp;
    type RpcId = Minter.RpcId; //Nat
    type RpcRequestId = Minter.RpcRequestId;
    type Value = Minter.Value;
    type RpcProvider = Minter.RpcProvider;
    type RpcLog = Minter.RpcLog;
    type RpcFetchLog = Minter.RpcFetchLog;
    type RpcRequestStatus = Minter.RpcRequestStatus;
    type RpcRequestConsensus = Minter.RpcRequestConsensus;
    
    /// RPC Provider List
    public type TrieRpcProviders = Trie.Trie<AccountId, RpcProvider>;
    /// RPC Out-call logs 
    public type TrieRpcLogs = Trie.Trie<RpcId, RpcLog>;
    /// RPC request logs (each request contains `minRpcConfirmations` RPC out-calls)
    public type TrieRpcRequests = Trie.Trie<RpcRequestId, RpcRequestConsensus>;
    /// Consensus process data cache for RPC requests (deleted after consensus is formed, or 12 hours after last update)
    public type TrieRpcRequestConsensusTemps = Trie.Trie<RpcRequestId, (confirmationStats: [([Value], Nat)], ts: Timestamp)>;

    private let ns_: Nat = 1000000000;
    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };
    private func _now() : Timestamp{
        return Int.abs(Time.now() / ns_);
    };
    
    private func statsConfirmations(_data: TrieRpcRequestConsensusTemps, _rid: RpcRequestId, _newRequestResult: [Value], _minConfirmedNum: Nat) : (TrieRpcRequestConsensusTemps, [Value], Nat, [([Value], Nat)]){
        var isMatched: Bool = false;
        var result: [Value] = [];
        var maxNum: Nat = 0;
        var confirmations: [([Value], Nat)] = [];
        var newConfirmations: [([Value], Nat)] = [];
        var data = _data;
        switch(Trie.get(data, keyn(_rid), Nat.equal)){
            case(?(_confirmations, _ts)){
                confirmations := _confirmations;
            };
            case(_){};
        };
        for ((r, n) in confirmations.vals()){
            if (r == _newRequestResult){
                isMatched := true;
                newConfirmations := Tools.arrayAppend(newConfirmations, [(r, n + 1)]);
                if (n+1 > maxNum){
                    result := r;
                    maxNum := n + 1;
                };
            }else{
                newConfirmations := Tools.arrayAppend(newConfirmations, [(r, n)]);
                if (n > maxNum){
                    result := r;
                    maxNum := n;
                };
            };
        };
        if (not(isMatched) and _newRequestResult.size() > 0){
            newConfirmations := Tools.arrayAppend(newConfirmations, [(_newRequestResult, 1)]);
            if (maxNum == 0){
                result := _newRequestResult;
                maxNum := 1;
            };
        };
        if (maxNum >= _minConfirmedNum){
            data := Trie.remove(data, keyn(_rid), Nat.equal).0;
        }else{
            data := Trie.put(data, keyn(_rid), Nat.equal, (newConfirmations, _now())).0;
        };
        data := Trie.filter(data, func (k: RpcRequestId, v: ([([Value], Nat)], Timestamp)): Bool{
            _now() < v.1 + 12 * 3600;
        });
        return (data, result, maxNum, newConfirmations);
    };
    // private func getRpcUrl(_data: TrieRpcProviders, _offset: Nat) : (keeper: AccountId, url: Text, total:Nat){
    //     let rpcs = Array.filter(Iter.toArray(Trie.iter<AccountId, RpcProvider>(_data)), func (t: (AccountId, RpcProvider)): Bool{
    //         t.1.status == #Available;
    //     });
    //     let length = rpcs.size();
    //     let rpc = rpcs[_offset % length];
    //     return (rpc.0, rpc.1.url, length);
    // };

    /// Jumping incremental values from positions 0/3, 1/3, 2/3 (avoiding consecutive values)
    public func threeSegIndex(i: Nat, n: Nat) : Nat{
        var r = 0;
        if (n >= 3 and i % 3 == 1){
            r := n / 3 + i / 3;
        }else if (n >= 3 and i % 3 == 2){
            r := n / 3 * 2 + i / 3;
        }else{
            r := i;
        };
        return r;
    };

    /// Pre-recorded RPC access log (record of one RPC-URL access)
    public func preRpcLog(_data: TrieRpcLogs, _id: RpcId, _url: Text, _input: Text) : (TrieRpcLogs){
        var data = _data;
        switch(Trie.get(data, keyn(_id), Nat.equal)){
            case(?(log)){ assert(false) };
            case(_){ 
                data := Trie.put(data, keyn(_id), Nat.equal, {
                    url= _url;
                    time = _now(); 
                    input = _input; 
                    result = null; 
                    err = null
                }).0; 
            };
        };
        return data;
    };

    /// Post-recorded RPC access log (result of one RPC-URL access)
    public func postRpcLog(_data: TrieRpcLogs, _id: RpcId, _result: ?Text, _err: ?Text) : (TrieRpcLogs){
        var data = _data;
        switch(Trie.get(data, keyn(_id), Nat.equal)){
            case(?(log)){
                data := Trie.put(data, keyn(_id), Nat.equal, {
                    url = log.url;
                    time = log.time; 
                    input = log.input; 
                    result = _result; 
                    err = _err
                }).0; 
            };
            case(_){};
        };
        return data;
    };
    
    public func putRpcRequestLog(_data: TrieRpcRequests, _conTemps: TrieRpcRequestConsensusTemps, _rid: RpcRequestId, _log: RpcFetchLog, _minConfirmedNum: Nat): 
    (TrieRpcRequests, TrieRpcRequestConsensusTemps, RpcRequestStatus){
        let thisSucceedNum : Nat = switch(_log.status){ case(#ok(v)){ 1 }; case(_){ 0 } };
        var consResult: RpcRequestStatus = #pending;
        var data = _data;
        var conTemps = _conTemps;
        switch(Trie.get(data, keyn(_rid), Nat.equal)){
            case(?(item)){
                var confirmedNum = item.confirmed;
                consResult := item.status;
                var requests: [RpcFetchLog] = item.requests;
                requests := Tools.arrayAppend(requests, [_log]);
                if (thisSucceedNum > 0 and consResult == #pending){
                    switch(_log.status){
                        case(#ok(v)){
                            let (temps, values, maxConfirmedNum, stats) = statsConfirmations(conTemps, _rid, v, _minConfirmedNum);
                            conTemps := temps;
                            confirmedNum := maxConfirmedNum;
                            if (confirmedNum >= _minConfirmedNum){
                                consResult := #ok(values);
                            };
                        };
                        case(_){};
                    };
                };
                data := Trie.put(data, keyn(_rid), Nat.equal, {
                    confirmed = confirmedNum; 
                    status = consResult;
                    requests = requests; 
                }).0;
            };
            case(_){
                if (thisSucceedNum > 0 and thisSucceedNum >= _minConfirmedNum){
                    consResult := _log.status;
                };
                data := Trie.put(data, keyn(_rid), Nat.equal, {
                    confirmed = thisSucceedNum; 
                    status = consResult;
                    requests = [_log]; 
                }).0;
            };
        };
        return (data, conTemps, consResult);
    };

    public func updateRpcProviderStats(_data: TrieRpcProviders, _intervalSeconds: Timestamp, _keeper: AccountId, _isSuccess: Bool): (TrieRpcProviders){
        var data = _data;
        switch(Trie.get(data, keyb(_keeper), Blob.equal)){
            case(?(provider)){
                var preHealthCheck = provider.preHealthCheck;
                var healthCheck = provider.healthCheck;
                if (_now() >= healthCheck.time + _intervalSeconds){
                    let lastHealthinessSlotTime = _now() / _intervalSeconds * _intervalSeconds;
                    preHealthCheck := healthCheck;
                    healthCheck := {time = lastHealthinessSlotTime; calls = 0; errors = 0; recentPersistentErrors = ?0};
                };
                var recentPersistentErrors = Option.get(healthCheck.recentPersistentErrors, 0);
                if (_isSuccess){
                    recentPersistentErrors := 0;
                }else{
                    recentPersistentErrors += 1;
                };
                healthCheck := {
                    time = healthCheck.time; 
                    calls = healthCheck.calls + 1; 
                    errors = healthCheck.errors + (if (_isSuccess){ 0 }else{ 1 }); 
                    recentPersistentErrors = ?recentPersistentErrors; 
                };
                var status = provider.status;
                if (recentPersistentErrors >= 10 or (healthCheck.calls >= 20 and healthCheck.errors * 100 / healthCheck.calls > 70)){
                    status := #Unavailable;
                };
                data := Trie.put(data, keyb(_keeper), Blob.equal, {
                    name = provider.name; 
                    url = provider.url; 
                    keeper = provider.keeper;
                    status = status; 
                    calls = provider.calls + 1; 
                    errors = provider.errors + (if (_isSuccess){ 0 }else{ 1 }); 
                    preHealthCheck = preHealthCheck;
                    healthCheck = healthCheck;
                    latestCall = _now();
                }).0;
            };
            case(_){};
        };
        return data;
    };

};