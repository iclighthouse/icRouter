/**
 * Module     : Cycles Monitor
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */

import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Trie "mo:base/Trie";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Error "mo:base/Error";
import Prelude "mo:base/Prelude";
import Cycles "mo:base/ExperimentalCycles";
import Hex "Hex";
import Ledger "Ledger";
import CF "CF";

/// private stable var cyclesMonitor: CyclesMonitor.MonitoredCanisters = Trie.empty(); 
/// private stable var lastMonitorTime: Time.Time = 0;
/// if (Time.now() > lastMonitorTime + _intervalSeconds * 1000000000){    };

module{
    public type canister_id = Principal;
    public type definite_canister_settings = {
        freezing_threshold : Nat;
        controllers : [Principal];
        memory_allocation : Nat;
        compute_allocation : Nat;
    };
    public type canister_status = {
        status : { #stopped; #stopping; #running };
        memory_size : Nat;
        cycles : Nat;
        settings : definite_canister_settings;
        module_hash : ?[Nat8];
    };
    public type IC = actor {
        canister_status : { canister_id : canister_id } -> async canister_status;
        deposit_cycles : shared { canister_id : canister_id } -> async ();
    };
    public type Blackhole = actor {
        canister_status : { canister_id : canister_id } -> async canister_status;
    };
    public type DRC207Support = {
        monitorable_by_self: Bool;
        monitorable_by_blackhole: { allowed: Bool; canister_id: ?Principal; };
        cycles_receivable: Bool;
        timer: { enable: Bool; interval_seconds: ?Nat; }; 
    };
    public type DRC207 = actor {
        drc207 : shared query () -> async DRC207Support;
        canister_status : shared () -> async canister_status;
    };
    let ICP_FEE: Nat64 = 10000;

    public type MonitoredCanisters = Trie.Trie<Principal, Nat>;

    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func _toSaNat8(_sa: ?Blob) : ?[Nat8]{
        switch(_sa){
            case(?(sa)){ return ?Blob.toArray(sa); };
            case(_){ return null; };
        }
    };
    private func sendIcpFromSA(_sa: ?Blob, _to: Blob, _value: Nat) : async* Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        let ledger: Ledger.Self = actor("ryjl3-tyaaa-aaaaa-aaaba-cai");
        let res = await ledger.transfer({
            to = _to;
            fee = { e8s = ICP_FEE; };
            memo = 9999;
            from_subaccount = _sa;
            created_at_time = null;
            amount = { e8s = amount };
        });
        return res;
    };
    public func icpToCycles(_this: Principal, _fromSa: ?Blob, _e8s: Nat) : async* CF.TxnResult{
        if (_e8s <= Nat64.toNat(ICP_FEE)) { throw Error.reject("Invalid value!"); };
        let cf: CF.Self = actor("6nmrm-laaaa-aaaak-aacfq-cai");
        var cfAccountId: Blob = Blob.fromArray([]);
        let aid = await cf.getAccountId(Principal.toText(_this));
        switch(Hex.decode(aid)){
            case(#ok(v)){ cfAccountId := Blob.fromArray(v) };
            case(_){ throw Error.reject("Invalid AccountId!"); };
        };
        let res = await* sendIcpFromSA(_fromSa, cfAccountId, _e8s);
        switch(res){
            case(#Err(e)){ throw Error.reject("ICP sending error! Check ICP balance!");};
            case(#Ok(blockHeight)){
                let res = await cf.icpToCycles(_e8s, _this, null, _toSaNat8(_fromSa), null);
                return res;
            };
        };
    };

    public func get_canister_status(_app: Principal) : async* canister_status{
        let ic: IC = actor("aaaaa-aa");
        let blackhole_canister = Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai");
        var canisterStatus: ?canister_status = null;
        try{
            canisterStatus := ?(await ic.canister_status({canister_id = _app }));
        }catch(e){
            let drc207: DRC207 = actor(Principal.toText(_app));
            let drc207Supports = await drc207.drc207();
            try{
                if (drc207Supports.monitorable_by_self){
                    canisterStatus := ?(await drc207.canister_status());
                }else{
                    throw Error.reject("");
                };
            }catch(e){
                if (drc207Supports.monitorable_by_blackhole.allowed){
                    let blackhole: Blackhole = actor(Principal.toText(Option.get(drc207Supports.monitorable_by_blackhole.canister_id, blackhole_canister)));
                    canisterStatus := ?(await blackhole.canister_status({canister_id = _app }));
                }else{
                    throw Error.reject("Cannot get canister status.");
                };
            };
        };
        return switch(canisterStatus){case(?status){ status }; case(_){ Prelude.unreachable() } };
    };

    public func topup(_canisters: MonitoredCanisters, _app: Principal, _initCycles: Nat) : async* MonitoredCanisters{
        let ic: IC = actor("aaaaa-aa");
        var canisters = _canisters;
        let canisterStatus = await* get_canister_status(_app);
        switch(Trie.get(_canisters, keyp(_app), Principal.equal)){
            case(?(totalCycles)){
                var addCycles: Nat = 0;
                if (totalCycles < _initCycles * 5 and canisterStatus.cycles < _initCycles * 2 / 3){
                    addCycles := _initCycles*2;
                }else if (totalCycles >= _initCycles * 5 and totalCycles < _initCycles * 20 and canisterStatus.cycles < _initCycles * 2){
                    addCycles := _initCycles*4;
                }else if (totalCycles >= _initCycles * 20 and totalCycles < _initCycles * 100 and canisterStatus.cycles < _initCycles * 4){
                    addCycles := _initCycles*8;
                }else if (totalCycles >= _initCycles * 100 and canisterStatus.cycles < _initCycles * 8){
                    addCycles := _initCycles*16;
                }else{};
                if (addCycles > 0){
                    Cycles.add(addCycles);
                    let res = await ic.deposit_cycles({canister_id = _app });
                    canisters := Trie.put(canisters, keyp(_app), Principal.equal, totalCycles+addCycles).0;
                };
            };
            case(_){
                canisters := Trie.put(canisters, keyp(_app), Principal.equal, canisterStatus.cycles).0;
            };
        };
        return canisters;
    };
    public func put(_canisters: MonitoredCanisters, _app: Principal) : async* MonitoredCanisters{
        let ic: IC = actor("aaaaa-aa");
        var canisters = _canisters;
        let canisterStatus = await* get_canister_status(_app);
        canisters := Trie.put(canisters, keyp(_app), Principal.equal, canisterStatus.cycles).0;
        return canisters;
    };
    public func remove(_canisters: MonitoredCanisters, _app: Principal) : MonitoredCanisters{
        var canisters = _canisters;
        canisters := Trie.remove(canisters, keyp(_app), Principal.equal).0;
        return canisters;
    };
    public func monitor(_this: Principal, _canisters: MonitoredCanisters, _initCycles: Nat, _minLocalCycles: Nat, _purchaseCyclesWithICPe8s: Nat) : 
    async* MonitoredCanisters{
        var canisters = _canisters;
        let cyclesBalance = Cycles.balance();
        if (cyclesBalance < _minLocalCycles and _purchaseCyclesWithICPe8s > 0){
            // Converting ICP to Cycles
            try{
                ignore await* icpToCycles(_this, null, _purchaseCyclesWithICPe8s);
            }catch(e){};
        };
        for ((canisterId, cycles) in Trie.iter(canisters)){
            try{
                canisters := await* topup(canisters, canisterId, _initCycles);
            }catch(e){};
        };
        return canisters;
    };
};