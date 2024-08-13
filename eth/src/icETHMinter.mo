/**
 * Module     : icETH Minter
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */

import Prelude "mo:base/Prelude";
import Prim "mo:prim";
import Trie "mo:base/Trie";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Deque "mo:base/Deque";
import Cycles "mo:base/ExperimentalCycles";
import ICRC1 "mo:icl/ICRC1";
import DRC20 "mo:icl/DRC20";
import ICTokens "mo:icl/ICTokens";
import Binary "mo:icl/Binary";
import Tools "mo:icl/Tools";
import SagaTM "mo:ictc/SagaTM";
import DRC207 "mo:icl/DRC207";
import Error "mo:base/Error";
import Result "mo:base/Result";
import ICECDSA "lib/ICECDSA";
import Minter "mo:icl/icETHMinter";
import ETHUtils "mo:icl/ETHUtils";
import ETHCrypto "lib/ETHCrypto";
import ABI "lib/ABI";
import Timer "mo:base/Timer";
import IC "mo:icl/IC";
import ICEvents "mo:icl/ICEvents";
import EIP712 "lib/EIP712";
import ICDex "mo:icl/ICDexTypes";
import KYT "mo:icl/KYT";
import CyclesMonitor "mo:icl/CyclesMonitor";
import RpcCaller "lib/RpcCaller";
import RpcRequest "lib/RpcRequest";
import Backup "lib/BackupTypes";

// Rules:
//      When depositing ETH, each account is processed in its own single thread.
// InitArgs = {
//     min_confirmations : ?Nat
//     rpc_confirmations: Nat;
//     tx_type: {#EIP1559; #EIP2930; #Legacy};
//     deposit_method: Nat8;
//   };
// Deploy:
// 1. Deploy minter canister 
// 2. addRpcWhitelist(domain)  setKeeper() and keeper_set_rpc()
// 3. sync() and setPause(false)
// 4. setCkTokenWasm() 
// 5. launchToken() 
// 6. setTokenDexPair() 
// Min confirmations in Production: 64 - 96
// "Ethereum/Sepolia", "ETH", 18, 12, record{min_confirmations=opt 96; rpc_confirmations = 3; tx_type = opt variant{EIP1559}; deposit_method=3}, true/false
shared(installMsg) actor class icETHMinter(initNetworkName: Text, initSymbol: Text, initDecimals: Nat8, initBlockSlot: Nat, initArgs: Minter.InitArgs, enDebug: Bool) = this {
    assert(Option.get(initArgs.min_confirmations, 0) >= 64); /*config*/

    type Cycles = Minter.Cycles;
    type Timestamp = Minter.Timestamp; // Nat, seconds
    type Sa = Minter.Sa; // [Nat8]
    type Txid = Minter.Txid; // blob
    type BlockHeight = Minter.BlockHeight; //Nat
    type ICRC1BlockHeight = Minter.ICRC1BlockHeight; //Nat
    type TxIndex = Minter.TxIndex; //Nat
    type TxHash = Minter.TxHash;
    type TxHashId = Minter.TxHashId;
    type RpcId = Minter.RpcId; //Nat
    type RpcRequestId = Minter.RpcRequestId;
    type KytId = Minter.KytId; //Nat
    type KytRequestId = Minter.KytRequestId;
    type ListPage = Minter.ListPage;
    type ListSize = Minter.ListSize;
    type Wei = Minter.Wei;
    type Gwei = Minter.Gwei; // 10**9
    type Ether = Minter.Ether; // 10**18

    type Account = Minter.Account;
    type AccountId = Minter.AccountId;
    type Address = Minter.Address;
    type EthAddress = Minter.EthAddress;
    type EthAccount = Minter.EthAccount;
    type EthAccountId = Minter.EthAccountId;
    type EthTokenId = Minter.EthTokenId;
    type TokenInfo = Minter.TokenInfo;
    type PubKey = Minter.PubKey;
    type DerivationPath = Minter.DerivationPath;
    type Hash = Minter.Hash;
    type HashId = Minter.HashId;
    type Nonce = Minter.Nonce;
    type HexWith0x = Minter.HexWith0x;
    type Transaction = Minter.Transaction;
    type Transaction1559 = Minter.Transaction1559;
    type DepositTxn = Minter.DepositTxn;
    type Status = Minter.Status;
    type Event = Minter.Event;
    type Keeper = Minter.Keeper;
    type Value = Minter.Value;
    type RpcProvider = Minter.RpcProvider;
    type RpcLog = Minter.RpcLog;
    type RpcRequestStatus = Minter.RpcRequestStatus;
    type RpcFetchLog = Minter.RpcFetchLog;
    type RpcRequestConsensus = Minter.RpcRequestConsensus;
    type MinterInfo = Minter.MinterInfo;
    type TrieList<K, V> = Minter.TrieList<K, V>; // {data: [(K, V)]; total: Nat; totalPage: Nat; };
    type EthGas = { gasPrice: Wei; gasLimit: Nat; maxFee: Wei;};
    type CkFee = {eth: Wei; token: Wei};
    type CustomCallType = {
        #getNonce: (TxIndex, ?[Nat]);
        #createTx: (TxIndex);
        #createTx_comp: (TxIndex);
        #signTx: (TxIndex);
        #sendTx: (TxIndex);
        #syncTx: (TxIndex, Bool);
        #validateTx: (TxHash);
        #burnNotify: (EthAddress, Wei, BlockHeight);
    };

    let KEY_NAME : Text = "key_1";
    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;
    let RPC_AGENT_CYCLES : Cycles = 200_000_000;
    let INIT_CKTOKEN_CYCLES: Cycles = 1000000000000; // 1T
    let ICTC_RUN_INTERVAL : Nat = 10;
    let MIN_VISIT_INTERVAL : Nat = 6; //seconds
    // let GAS_PER_BYTE : Nat = 68; // gas
    let MAX_PENDING_RETRIEVALS : Nat = 50; /*config*/
    let VALID_BLOCKS_FOR_CLAIMING_TXN: Nat = 432000; // 60 days
    
    private stable var app_debug : Bool = enDebug; // Cannot be modified
    private let version_: Text = "0.9.0"; /*config*/
    private let ns_: Nat = 1000000000;
    private let gwei_: Nat = 1000000000;
    private let minCyclesBalance: Nat = 200_000_000_000; // 0.2 T
    private stable var minConfirmations : Nat = Option.get(initArgs.min_confirmations, 64);
    private stable var minRpcConfirmations : Nat = initArgs.rpc_confirmations;
    private stable var paused: Bool = true;
    private stable var ckTxType = Option.get(initArgs.tx_type, #EIP1559);
    private stable var ckNetworkName: Text = initNetworkName;
    private stable var ckNetworkSymbol: Text = initSymbol;
    private stable var ckNetworkDecimals: Nat8 = initDecimals;
    private stable var ckNetworkBlockSlot: Nat = initBlockSlot;
    private stable var owner: Principal = installMsg.caller;
    private stable var depositMethod: Nat8 = initArgs.deposit_method;
    private let txTaskAttempts: Nat = 30;
    
    private stable var ic_: Principal = Principal.fromText("aaaaa-aa"); 
    private let eth_: Text = "0x0000000000000000000000000000000000000000";
    private let sa_zero : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]; // Main account
    private let sa_one : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]; // Fees account
    private let sa_two : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2]; // Fee Swap
    private let ic : ICECDSA.Self = actor(Principal.toText(ic_));
    private let ecContext = ETHCrypto.getEcContext();
    private var blackhole_: Text = "7hdtw-jqaaa-aaaak-aaccq-cai";
    private stable var icrc1WasmHistory: [(wasm: [Nat8], version: Text)] = [];
    private stable var rpcDomainWhitelist: [Text] = [];

    private stable var countMinting: Nat = 0;
    private stable var totalMinting: Wei = 0; // ETH
    private stable var countRetrieval: Nat = 0;
    private stable var totalRetrieval: Wei = 0; // ETH
    private stable var latestVisitTime = Trie.empty<Principal, Timestamp>(); 
    private stable var accounts = Trie.empty<AccountId, (EthAddress, Nonce)>(); 
    private stable var tokens = Trie.empty<EthAddress, TokenInfo>(); 
    private stable var quoteToken: EthAddress = "";
    private stable var deposits = Trie.empty<AccountId, TxIndex>(); // pending temp
    private stable var balances: Trie.Trie2D<AccountId, EthTokenId, (Account, Wei)> = Trie.empty();  //Wei
    // Pool Balances: balances: Trie.Trie2D<this, EthTokenId, (Account, Wei)> = Trie.empty();  //Wei
    private stable var feeBalances = Trie.empty<EthTokenId, Wei>(); // Fees account: ckETH or ckERC20 tokens
    private stable var retrievals = Trie.empty<TxIndex, Minter.RetrieveStatus>();  // Persistent storage
    private stable var withdrawals = Trie.empty<AccountId, List.List<TxIndex>>(); // Persistent storage
    private stable var pendingRetrievals = List.nil<TxIndex>(); // pending temp
    private stable var txIndex : TxIndex = 0;
    private stable var transactions = Trie.empty<TxIndex, (tx: Minter.TxStatus, ts: Timestamp, coveredTime: ?Timestamp)>(); // Persistent storage
    private stable var depositTxns = Trie.empty<TxHashId, (tx: DepositTxn, updatedTime: Timestamp)>();    // Method 2: Persistent storage
    private stable var pendingDepositTxns = Trie.empty<TxHashId, Minter.PendingDepositTxn>();    // Method 2: pending temp
    private stable var failedTxns = Deque.empty<TxHashId>();
    private stable var lastGetGasPriceTime: Timestamp = 0;
    private var getGasPriceIntervalSeconds: Timestamp = 10 * 60;/*config*/
    private stable var lastUpdateTokenPriceTime: Timestamp = 0;
    private var getTokenPriceIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {4 * 3600};/*config*/
    private stable var lastConvertFeesTime: Timestamp = 0;
    private var convertFeesIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {8 * 3600};/*config*/
    private var healthinessIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {7 * 24 * 3600};/*config*/
    private stable var countRejections: Nat = 0;
    private stable var lastExecutionDuration: Int = 0;
    private stable var maxExecutionDuration: Int = 0;
    private stable var lastSagaRunningTime : Time.Time = 0;
    private stable var countAsyncMessage : Nat = 0;

    private stable var ck_chainId : Nat = 1; 
    private stable var ck_ethBlockNumber: (blockheight: BlockHeight, time: Timestamp) = (0, 0); 
    private stable var ck_gasPrice: Wei = 5_000_000_000; // Wei 
    private stable var ck_keepers = Trie.empty<AccountId, Keeper>(); 
    private stable var ck_rpcProviders = Trie.empty<AccountId, RpcProvider>(); 
    private stable var    rpcId: RpcId = 0;
    private stable var    firstRpcId: RpcId = 0;
    private stable var ck_rpcLogs = Trie.empty<RpcId, RpcLog>(); 
    private stable var    rpcRequestId: RpcRequestId = 0;
    private stable var    firstRpcRequestId: RpcRequestId = 0;
    private stable var ck_rpcRequests = Trie.empty<RpcRequestId, RpcRequestConsensus>(); 
    private stable var ck_rpcRequestConsensusTemps = Trie.empty<RpcRequestId, (confirmationStats: [([Value], Nat)], ts: Timestamp)>(); 

    // KYT
    private stable var kyt_accountAddresses: KYT.AccountAddresses = Trie.empty(); 
    private stable var kyt_addressAccounts: KYT.AddressAccounts = Trie.empty(); 
    private stable var kyt_txAccounts: KYT.TxAccounts = Trie.empty(); 
    // Events
    private stable var blockIndex : BlockHeight = 0;
    private stable var firstBlockIndex : BlockHeight = 0;
    private stable var blockEvents : ICEvents.ICEvents<Event> = Trie.empty(); 
    private stable var accountEvents : ICEvents.AccountEvents = Trie.empty(); 
    // Monitor
    private stable var cyclesMonitor: CyclesMonitor.MonitoredCanisters = Trie.empty(); 
    private stable var lastMonitorTime: Nat = 0;

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };
    private func trieItems<K, V>(_trie: Trie.Trie<K,V>, _page: ListPage, _size: ListSize) : TrieList<K, V> {
        return Tools.trieItems<K, V>(_trie, _page, _size);
    };
    // tools
    private func _now() : Timestamp{
        return Int.abs(Time.now() / ns_);
    };
    private func _onlyOwner(_caller: Principal) : Bool { //ict
        return _caller == owner;
    }; 
    private func _onlyKeeper(_account: AccountId) : Bool {
        switch(Trie.get(ck_keepers, keyb(_account), Blob.equal)){
            case(?(keeper)){ return keeper.status == #Normal };
            case(_){ return false };
        };
    }; 
    private func _onlyTxCaller(_account: AccountId, _txi: TxIndex) : Bool {
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                return _account == accountId;
            };
            case(_){ return false; };
        };
    }; 
    private func _notPaused() : Bool { 
        return not(paused);
    };
    private func _asyncMessageSize() : Nat{
        return countAsyncMessage + _getSaga().asyncMessageSize();
    };
    private func _checkAsyncMessageLimit() : Bool{
        return _asyncMessageSize() < 390; /*config*/
    };
    // cycles limit
    private func _checkCycles(): Bool{
        return Cycles.balance() > minCyclesBalance;
    };
    
    private func _toSaBlob(_sa: ?Sa) : ?Blob{
        switch(_sa){
            case(?(sa)){ return ?Blob.fromArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toSaNat8(_sa: ?Blob) : ?[Nat8]{
        switch(_sa){
            case(?(sa)){ return ?Blob.toArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toOptSub(_sub: Blob) : ?Blob{
        if (Blob.toArray(_sub).size() == 0){
            return null;
        }else{
            return ?_sub;
        };
    };
    private func _natToFloat(_n: Nat) : Float{
        let n: Int = _n;
        return Float.fromInt(n);
    };
    private func _floatToNat(_f: Float) : Nat{
        let i = Float.toInt(_f);
        assert(i >= 0);
        return Int.abs(i);
    };
    private func _toLower(_text: Text): Text{
        return Text.map(_text , Prim.charToLower);
    };
    private func _accountId(_owner: Principal, _subaccount: ?[Nat8]) : Blob{
        return Blob.fromArray(Tools.principalToAccount(_owner, _subaccount));
    };
    private func _getAccountId(_address: Address): AccountId{
        switch (Tools.accountHexToAccountBlob(_address)){
            case(?(a)){
                return a;
            };
            case(_){
                var p = Principal.fromText(_address);
                var a = Tools.principalToAccountBlob(p, null);
                return a;
                // switch(Tools.accountDecode(Principal.toBlob(p))){
                //     case(#ICRC1Account(account)){
                //         switch(account.subaccount){
                //             case(?(sa)){ return Tools.principalToAccountBlob(account.owner, ?Blob.toArray(sa)); };
                //             case(_){ return Tools.principalToAccountBlob(account.owner, null); };
                //         };
                //     };
                //     case(#AccountId(account)){ return account; };
                //     case(#Other(account)){ return account; };
                // };
            };
        };
    }; 
    private func _txTaskInterval() : Int{
        return (ckNetworkBlockSlot * minConfirmations * 2 / txTaskAttempts) * 1_000_000_000;
    };

    private func _isRpcDomainWhitelist(_rpcUrl: Text) : Bool{
        let rpcDomain = _getRpcDomain(_rpcUrl);
        return Option.isSome(Array.find(rpcDomainWhitelist, func (t: Text): Bool{ t == rpcDomain }));
    };
    private func _addRpcDomainWhitelist(_rpcDomain: Text) : (){
        _removeRpcDomainWhitelist(_rpcDomain);
        rpcDomainWhitelist := Tools.arrayAppend(rpcDomainWhitelist, [_toLower(_rpcDomain)]);
    };
    private func _removeRpcDomainWhitelist(_rpcDomain: Text) : (){
        rpcDomainWhitelist := Array.filter(rpcDomainWhitelist, func (t: Text): Bool{ t != _toLower(_rpcDomain) });
    };
    private func _getRpcDomain(_rpcUrl: Text) : Text{
        return RpcCaller.getHost(_toLower(_rpcUrl));
    };
    private func _removeProviders(_rpcDomain: Text) : (){
        ck_rpcProviders := Trie.filter(ck_rpcProviders, func (k: AccountId, v: RpcProvider): Bool{
            _getRpcDomain(v.url) != _toLower(_rpcDomain)
        });
    };

    // Local tasks
    private func _local_getNonce(_txi: TxIndex, _toids: ?[Nat]) : async* {txi: Nat; address: EthAddress; nonce: Nonce}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Building){
                    var accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    var nonce : Nat = 0;
                    if (tx.txType == #Withdraw or tx.txType == #DepositGas){ 
                        accountId := _accountId(Principal.fromActor(this), null);
                        let (_mainAddress, mainNonce) = _getEthAddressQuery(accountId);
                        nonce := mainNonce;
                    }else{
                        nonce := await* _fetchAccountNonce(tx.from, #pending);
                    };
                    _setEthAccount(accountId, tx.from, nonce + 1);
                    _updateTx(_txi, {
                        fee = null;
                        amount = null;
                        nonce = ?nonce;
                        toids = _toids;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcRequestId = null;
                        kytRequestId = null;
                        status = null;
                        ts = null;
                    }, null);
                    return {txi = _txi; address = tx.from; nonce = nonce};
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_createTx(_txi: TxIndex) : async* {txi: Nat; rawTx: [Nat8]; txHash: TxHash}{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Building){
                    let isERC20 = tx.tokenId != eth_;
                    var txObj: Transaction = ETHCrypto.buildTransaction(tx, ckTxType, ck_chainId, isERC20, null, null);
                    try{
                        // countAsyncMessage += 1;
                        let rawTx = ETHCrypto.rlpEncode(txObj); 
                        let txHash = ETHCrypto.sha3(rawTx);
                            _updateTx(_txi, {
                                fee = null;
                                amount = null;
                                nonce = null;
                                toids = null;
                                txHash = null; // ?ABI.toHex(txHash);
                                tx = ?txObj;
                                rawTx = ?(rawTx, txHash);
                                signedTx = null;
                                receipt = null;
                                rpcRequestId = null;
                                kytRequestId = null;
                                status = ?#Signing;
                                ts = ?_now();
                            }, null);
                            return {txi = _txi; rawTx = rawTx; txHash = ABI.toHex(txHash)};
                    }catch(e){
                        // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                        throw Error.reject("Calling error: "# Error.message(e)); 
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_createTx_comp(_txi: TxIndex) : async* (){
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Signing){
                    _updateTx(_txi, {
                        fee = null;
                        amount = null;
                        nonce = null;
                        toids = null;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcRequestId = null;
                        kytRequestId = null;
                        status = ?#Building;
                        ts = ?_now();
                    }, null);
                }else{
                    throw Error.reject("402: The status of transaction is not #Signing!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_signTx(_txi: TxIndex) : async* {txi: Nat; signature: [Nat8]; rawTx: [Nat8]; txHash: TxHash}{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Signing or tx.status == #Sending or tx.status == #Pending){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    var dpath = [accountId];
                    var userAddress = tx.from;
                    if (tx.txType == #Withdraw or tx.txType == #DepositGas){ 
                        dpath := [_accountId(Principal.fromActor(this), null)] ;
                        userAddress := tx.to;
                    };
                    switch(tx.tx, tx.rawTx){
                        case(?txn, ?(msgRaw, hash)){
                            let signature = await* _sign(dpath, hash);
                            var signValues = {r: [Nat8] = []; s: [Nat8] = []; v: Nat64 = 0};
                            switch(ETHCrypto.convertSignature(signature, hash, tx.from, ck_chainId, ecContext)){
                                case(#ok(rsv)){ signValues := rsv };
                                case(#err(e)){ throw Error.reject(e); };
                            };
                            let signedValues: ETHUtils.Signature = {r = signValues.r; s = signValues.s; v = signValues.v; from = ABI.fromHex(tx.from); hash = hash };
                            let txObjNew: Transaction = ETHCrypto.buildSignedTransaction(txn, ?signedValues);
                            // 0x2(EIP1559) || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, signatureYParity, signatureR, signatureS])
                            let signedTx = ETHCrypto.rlpEncode(txObjNew);
                            let signedHash = ETHCrypto.sha3(signedTx);
                            _updateTx(_txi, {
                                fee = null;
                                amount = null;
                                nonce = null;
                                toids = null;
                                txHash = ?ABI.toHex(signedHash);
                                tx = ?txObjNew;
                                rawTx = null;
                                signedTx = ?(signedTx, signedHash);
                                receipt = null;
                                rpcRequestId = null;
                                kytRequestId = null;
                                status = ?#Sending;
                                ts = ?_now();
                            }, null);
                            _putTxAccount(tx.tokenId, ABI.toHex(signedHash), userAddress, tx.account);
                            return {txi = _txi; signature = signature; rawTx = signedTx; txHash = ABI.toHex(signedHash)};
                        };
                        case(_, _){
                            throw Error.reject("402: There is no tx or tx hash!");
                        };
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Signing!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_sendTx(_txi: TxIndex) : async* {txi: Nat; result: Result.Result<TxHash, Text>; rpcId: RpcRequestId}{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Sending){
                    switch(tx.signedTx){
                        case(?(raw, hash)){
                            switch(await* _sendRawTx(raw)){
                                case((requestId, #ok(txid))){
                                    _updateTx(_txi, {
                                        fee = null;
                                        amount = null;
                                        nonce = null;
                                        toids = null;
                                        txHash = null;
                                        tx = null;
                                        rawTx = null;
                                        signedTx = null;
                                        receipt = null;
                                        rpcRequestId = ?requestId;
                                        kytRequestId = null;
                                        status = ?#Submitted;
                                        ts = ?_now();
                                    }, null);
                                    return {txi = _txi; result = #ok(txid); rpcId = requestId};
                                };
                                case((requestId, #err(e))){
                                    if (_isNormalRpcReturn(e)){
                                        _updateTx(_txi, {
                                            fee = null;
                                            amount = null;
                                            nonce = null;
                                            toids = null;
                                            txHash = null;
                                            tx = null;
                                            rawTx = null;
                                            signedTx = null;
                                            receipt = null;
                                            rpcRequestId = ?requestId;
                                            kytRequestId = null;
                                            status = ?#Submitted;
                                            ts = ?_now();
                                        }, null);
                                        return {txi = _txi; result = #err(e); rpcId = requestId};
                                    } else{
                                        _updateTx(_txi, {
                                            fee = null;
                                            amount = null;
                                            nonce = null;
                                            toids = null;
                                            txHash = null;
                                            tx = null;
                                            rawTx = null;
                                            signedTx = null;
                                            receipt = null;
                                            rpcRequestId = ?requestId;
                                            kytRequestId = null;
                                            status = null;
                                            ts = null;
                                        }, null);
                                        throw Error.reject("402: (requestId="# Nat.toText(requestId) #")" # e);
                                    };
                                };
                            };
                        };
                        case(_){
                            throw Error.reject("402: The transaction raw does not exist!");
                        };
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_syncTx(_txi: TxIndex, _rapidly: Bool) : async* {txi: Nat; completed: Bool; status: Minter.Status}{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Confirmed){
                    return {txi = _txi; completed = true; status = tx.status}; // #ok
                }else if (tx.status == #Failure){
                    throw Error.reject("406: Failure. "# debug_show({txi = _txi; completed = true; status = tx.status}) # 
                    " (Notice: In the case of an `insufficient balance` error, there may be a transaction anomaly, so it is prudent to use the `resend` compensation.)");
                }else if (not(_rapidly) and _now() < ts + ckNetworkBlockSlot * minConfirmations){
                    throw Error.reject("407.1: Waiting. "# debug_show({txi = _txi; completed = false; status = tx.status}));
                }else{
                    let (completed, confirming, status) = await* _txCompletedAndCallback(_txi);
                    if (completed and status == #Confirmed){
                        return {txi = _txi; completed = completed; status = status}; // #ok
                    }else if (completed and status == #Failure){
                        throw Error.reject("406: Failure. "# debug_show({txi = _txi; completed = completed; status = status}) # 
                        " (Notice: In the case of an `insufficient balance` error, there may be a transaction anomaly, so it is prudent to use the `resend` compensation.)");
                    }else{
                        throw Error.reject("407.2: Pending. "# debug_show({txi = _txi; completed = completed; status = status}));
                    };
                };
            };
            case(_){ throw Error.reject("404: The transaction record does not exist!"); };
        };
    };
    private func _local_validateTx(_txHash: TxHash) : async* {txHash: TxHash; completed: Bool; status: Minter.Status; message: ?Text; token: ?Text; amount: ?Nat}{
        switch(await* _syncMethod2TxnStatus(_txHash)){
            case(#Confirmed, message, token, amount){
                return {txHash = _txHash; completed = true; status = #Confirmed; message = message; token = token; amount = amount}; // #ok
            };
            case(#Failure, message, token, amount){
                let res = {txHash = _txHash; completed = true; status = #Failure; message = message; token = token; amount = amount}; // Failure
                throw Error.reject("410: Failure. "# Option.get(message, ""));
            };
            case(#Pending, message, token, amount){
                throw Error.reject("408: Pending. "# Option.get(message, ""));
            };
            case(_, message, token, amount){
                throw Error.reject("409: Unkown error. "# Option.get(message, ""));
            };
        };
    }; 
    private func _local_burnNotify(_ethAddress: EthAddress, _amount: Wei, _height: BlockHeight) : async* {token: EthAddress; amount: Wei}{
        // do nothing
        return {token = _ethAddress; amount = _amount };
    };
    
    // Local task entrance
    private func _customCall(_callee: Principal, _cycles: Nat, _args: SagaTM.CallType<CustomCallType>, _receipt: ?SagaTM.Receipt) : async (SagaTM.TaskResult){
        switch(_args){
            case(#custom(method)){
                switch(method){
                    case(#getNonce(_txi, _toids)){
                        let result = await* _local_getNonce(_txi, _toids);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(result.txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#createTx(_txi)){
                        let result = await* _local_createTx(_txi);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(result.txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };case(#createTx_comp(_txi)){
                        let result = await* _local_createTx_comp(_txi);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(_txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#signTx(_txi)){
                        let result = await* _local_signTx(_txi);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(result.txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#sendTx(_txi)){
                        let result = await* _local_sendTx(_txi);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(result.txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#syncTx(_txi, _rapidly)){
                        let result = await* _local_syncTx(_txi, _rapidly);
                        // txi(32bytes)
                        let resultRaw = ABI.natABIEncode(result.txi);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#validateTx(_txHash)){
                        let result = await* _local_validateTx(_txHash);
                        // txHash(32bytes)
                        let resultRaw = Option.get(ABI.fromHex(result.txHash), []);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#burnNotify(_ethAddress, _amount, _height)){
                        let result = await* _local_burnNotify(_ethAddress, _amount, _height);
                        // token(32bytes)
                        let resultRaw = ABI.addressABIEncode(result.token);
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    //case(_){return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
                };
            };
            case(_){ return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
        };
    };
    // Task callback
    // private func _taskCallback(_toName: Text, _ttid: SagaTM.Ttid, _task: SagaTM.Task, _result: SagaTM.TaskResult) : (){
    //     //taskLogs := Tools.arrayAppend(taskLogs, [(_ttid, _task, _result)]);
    // };
    // // Order callback
    // private func _orderCallback(_toName: Text, _toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _data: ?Blob) : (){
    //     //orderLogs := Tools.arrayAppend(orderLogs, [(_toid, _status)]);
    // };
    // Create saga object
    private var saga: ?SagaTM.SagaTM<CustomCallType> = null;
    private func _getSaga() : SagaTM.SagaTM<CustomCallType> {
        switch(saga){
            case(?(_saga)){ return _saga };
            case(_){
                let _saga = SagaTM.SagaTM<CustomCallType>(Principal.fromActor(this), ?_customCall, null, null); //?_taskCallback, ?_orderCallback
                saga := ?_saga;
                return _saga;
            };
        };
    };
    private func _ictcSagaRun(_toid: Nat, _forced: Bool): async* (){
        if (_forced or _checkAsyncMessageLimit()){ 
            lastSagaRunningTime := Time.now();
            let saga = _getSaga();
            if (_toid == 0){
                try{
                    // countAsyncMessage += 1;
                    let _sagaRes = await* saga.getActuator().run();
                    // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                }catch(e){
                    // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            }else{
                try{
                    // countAsyncMessage += 2;
                    let _sagaRes = await saga.run(_toid);
                    // countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    // countAsyncMessage -= Nat.min(2, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            };
        };
    };
    private func _buildTask(_data: ?Blob, _callee: Principal, _callType: SagaTM.CallType<CustomCallType>, _preTtid: [SagaTM.Ttid], _cycles: Nat, _attempts: ?Nat, _interval: ?Int) : SagaTM.PushTaskRequest<CustomCallType>{
        return {
            callee = _callee;
            callType = _callType;
            preTtid = _preTtid;
            attemptsMax = _attempts;
            recallInterval = _interval; // nanoseconds
            cycles = _cycles;
            data = _data;
        };
    };
    private func _checkICTCError() : (){
        let count = _getSaga().getBlockingOrders().size();
        if (count >= 5){
            paused := true;
            ignore _putEvent(#suspend({message = ?"The ICTC transaction reported errors and the system was suspended."}), ?_accountId(owner, null));
        };
    };
    private func _ictcAllDone(): Bool{
        let tos = _getSaga().getAliveOrders();
        var res: Bool = true;
        for ((toid, order) in tos.vals()){
            switch(order){
                case(?(order_)){
                    if (order_.status != #Done and order_.status != #Recovered){
                        res := false;
                    };
                };
                case(_){};
            };
        };
        return res;
    };
    private func _ictcDone(_toids: [SagaTM.Toid]) : Bool{
        var completed: Bool = true;
        for (toid in _toids.vals()){
            let status = _getSaga().status(toid);
            if (status != ?#Done and status != ?#Recovered and status != null){
                completed := false;
            };
        };
        return completed;
    };
    // private functions
    private func _isCkToken(_tokenId: EthAddress) : Bool{
        return Option.isSome(Trie.get(tokens, keyt(_tokenId), Text.equal));
    };
    private func _getCkTokenInfo(_tokenId: EthAddress) : TokenInfo{
        switch(Trie.get(tokens, keyt(_tokenId), Text.equal)){
            case(?(token)){ token };
            case(_){ 
                Prelude.unreachable();
             };
        };
    };
    private func _getCkLedger(_tokenId: EthAddress) : ICRC1.Self{
        return actor(Principal.toText(_getCkTokenInfo(_tokenId).ckLedgerId));
    };
    private func _getCkDRC20(_tokenId: EthAddress) : DRC20.Self{
        return actor(Principal.toText(_getCkTokenInfo(_tokenId).ckLedgerId));
    };
    private func _getICTokens(_tokenId: EthAddress) : ICTokens.Self{
        return actor(Principal.toText(_getCkTokenInfo(_tokenId).ckLedgerId));
    };
    private func _getTokenMinAmount(_tokenId: EthAddress) : Wei{
        switch(Trie.get(tokens, keyt(_tokenId), Text.equal)){
            case(?(token)){ token.minAmount };
            case(_){ 0 };
        };
    };
    private func _setEthAccount(_a: AccountId, _ethaccount: EthAddress, _nonce: Nonce) : (){
        accounts := Trie.put(accounts, keyb(_a), Blob.equal, (_ethaccount, _nonce)).0;
    };
    private func _getRpcUrl(_offset: Nat) : (keeper: AccountId, url: Text, total:Nat){
        let rpcs = Array.filter(Iter.toArray(Trie.iter<AccountId, RpcProvider>(ck_rpcProviders)), func (t: (AccountId, RpcProvider)): Bool{
            t.1.status == #Available;
        });
        let length = rpcs.size();
        let rpc = rpcs[_offset % length];
        return (rpc.0, rpc.1.url, length);
    };
    private func _getBlockNumber() : Nat{
        return ck_ethBlockNumber.0 + (_now() - ck_ethBlockNumber.1) / ckNetworkBlockSlot;
    };
    private func _getEthAddressQuery(_a: AccountId) : (EthAddress, Nonce){
        var address: EthAddress = "";
        var nonce: Nonce = 0;
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account_, nonce_)){
                address := account_;
                nonce := nonce_;
            };
            case(_){};
        };
        return (address, nonce);
    };
    private func _getEthAddress(_a: AccountId, _updateNonce: Bool) : async* (EthAddress, Nonce){
        var address: EthAddress = "";
        var nonce: Nonce = 0;
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account_, nonce_)){
                address := account_;
                nonce := nonce_;
                if (_updateNonce){
                    let nonceNew = await* _fetchAccountNonce(address, #pending);
                    _setEthAccount(_a, address, nonceNew);
                    nonce := nonceNew;
                };
            };
            case(_){
                let account = await* _fetchAccountAddress([_a]);
                if (account.1.size() > 0){
                    let nonceNew = await* _fetchAccountNonce(account.2, #pending);
                    _setEthAccount(_a, account.2, nonceNew);
                    address := account.2;
                    nonce := nonceNew;
                };
            };
        };
        assert(Text.size(address) == 42);
        return (address, nonce);
    };
    private func _getEthAccount(_address: EthAddress): EthAccount{
        switch(ABI.fromHex(_address)){
            case(?(a)){ a };
            case(_){ assert(false); [] };
        };
    };
    private func _getLatestIcrc1Wasm(): (wasm: [Nat8], version: Text){
        if (icrc1WasmHistory.size() == 0){ 
            return ([], ""); 
        }else{
            return icrc1WasmHistory[0];
        };
    };

    private func _getFeeBalance(_tokenId: EthAddress) : (balance: Wei){
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        switch(Trie.get(feeBalances, keyb(tokenId), Blob.equal)){
            case(?(v)){
                return v;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _setFeeBalance(_tokenId: EthAddress, _amount: Wei): (){
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        feeBalances := Trie.put(feeBalances, keyb(tokenId), Blob.equal, _amount).0;
    };
    private func _addFeeBalance(_tokenId: EthAddress, _amount: Wei): (balance: Wei){
        var balance = _getFeeBalance(_tokenId);
        balance += _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (balance > 0){
            feeBalances := Trie.put(feeBalances, keyb(tokenId), Blob.equal, balance).0;
        };
        return balance;
    };
    private func _subFeeBalance(_tokenId: EthAddress, _amount: Wei): (balance: Wei){
        var balance = _getFeeBalance(_tokenId);
        if (balance >= _amount){
            balance -= _amount;
        }else{
            // Do a check on the account funds before deducting them.
            Prelude.unreachable();
        };
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (balance > 0){
            feeBalances := Trie.put(feeBalances, keyb(tokenId), Blob.equal, balance).0;
        }else{
            feeBalances := Trie.remove(feeBalances, keyb(tokenId), Blob.equal).0;
        };
        return balance;
    };
    private func _getBalance(_account: Account, _tokenId: EthAddress) : (balance: Wei){
        let accountId = _accountId(_account.owner, _account.subaccount);
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        switch(Trie.get(balances, keyb(accountId), Blob.equal)){
            case(?(trie)){
                switch(Trie.get(trie, keyb(tokenId), Blob.equal)){
                    case(?(a, v)){
                        return v;
                    };
                    case(_){
                        return 0;
                    };
                };
            };
            case(_){
                return 0;
            };
        };
    };
    private func _setBalance(_account: Account, _tokenId: EthAddress, _amount: Wei): (){
        let accountId = _accountId(_account.owner, _account.subaccount);
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        balances := Trie.put2D(balances, keyb(accountId), Blob.equal, keyb(tokenId), Blob.equal, (_account, _amount));
    };
    private func _addBalance(_account: Account, _tokenId: EthAddress, _amount: Wei): (balance: Wei){
        let accountId = _accountId(_account.owner, _account.subaccount);
        var balance = _getBalance(_account, _tokenId);
        balance += _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (balance > 0){
            balances := Trie.put2D(balances, keyb(accountId), Blob.equal, keyb(tokenId), Blob.equal, (_account, balance));
        };
        return balance;
    };
    private func _subBalance(_account: Account, _tokenId: EthAddress, _amount: Wei): (balance: Wei){
        let accountId = _accountId(_account.owner, _account.subaccount);
        var balance = _getBalance(_account, _tokenId);
        if (balance >= _amount){
            balance -= _amount;
        }else{
            // Do a check on the account funds before deducting them. Theoretically, the pool account is sufficient to go through the deduction.
            Prelude.unreachable();
        };
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (balance > 0){
            balances := Trie.put2D(balances, keyb(accountId), Blob.equal, keyb(tokenId), Blob.equal, (_account, balance));
        }else{
            balances := Trie.remove2D(balances, keyb(accountId), Blob.equal, keyb(tokenId), Blob.equal).0;
            switch(Trie.get(balances, keyb(accountId), Blob.equal)){
                case(?tb){
                    if (Trie.size(tb) == 0){
                        balances := Trie.remove(balances, keyb(accountId), Blob.equal).0;
                    };
                };
                case(_){};
            };
        };
        return balance;
    };
    private func _isPending(_txi: TxIndex) : Bool{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){ return tx.status != #Confirmed and tx.status != #Failure; };
            case(_){ return false };
        };
    };
    private func _getDepositingTxIndex(_a: AccountId) : ?TxIndex{
        switch(Trie.get(deposits, keyb(_a), Blob.equal)){
            case(?(ti)){ ?ti };
            case(_){ null };
        };
    };
    private func _putDepositingTxIndex(_a: AccountId, _txi: TxIndex) : (){
        deposits := Trie.put(deposits, keyb(_a), Blob.equal, _txi).0;
    };
    private func _removeDepositingTxIndex(_a: AccountId, _txIndex: TxIndex) : ?TxIndex{
        switch(Trie.get(deposits, keyb(_a), Blob.equal)){
            case(?(ti)){
                if (ti == _txIndex){
                    deposits := Trie.remove(deposits, keyb(_a), Blob.equal).0;
                    return ?ti;
                };
            };
            case(_){};
        };
        return null;
    };
    private func _putRetrievingTxIndex(_txi: TxIndex) : (){
        pendingRetrievals := List.push(_txi, pendingRetrievals);
    }; 
    private func _removeRetrievingTxIndex(_txi: TxIndex) : (){
        pendingRetrievals := List.filter(pendingRetrievals, func (t: TxIndex): Bool{ t != _txi });
    };
    private func _isRetrieving(_txi: TxIndex) : Bool{
        return Option.isSome(List.find(pendingRetrievals, func (t: TxIndex): Bool{ t == _txi }));
    };
    private func _getPendingDepositTxn(_txHash: TxHash) : ?Minter.PendingDepositTxn{
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        return Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal);
    };
    private func _putPendingDepositTxn(_account: Account, _txHash: TxHash, _signature: [Nat8], _toid: ?SagaTM.Toid) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(txHash), Blob.equal, (_txHash, _account, _signature, false, _now(), _toid)).0;
    };
    private func _putToidToPendingDepositTxn(_txHash: TxHash, _toid: ?SagaTM.Toid) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal)){
            case(?(pending)){
                pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(txHash), Blob.equal, (pending.0, pending.1, pending.2, pending.3, pending.4, _toid)).0;
            };
            case(_){};
        };
    };
    private func _validatePendingDepositTxn(_txHash: TxHash) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal)){
            case(?(pending)){
                pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(txHash), Blob.equal, (pending.0, pending.1, pending.2, true, pending.4, pending.5)).0;
            };
            case(_){};
        };
    };
    private func _removePendingDepositTxn(_txHash: TxHash) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        pendingDepositTxns := Trie.remove(pendingDepositTxns, keyb(txHash), Blob.equal).0;
    };
    private func _putFailedTxnLog(_txHash: TxHash) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        failedTxns := Deque.pushFront(failedTxns, txHash);
        if (List.size(failedTxns.0) + List.size(failedTxns.1) > 500){
            switch(Deque.popBack(failedTxns)){
                case(?(q, t)){ 
                    failedTxns := q;
                    switch(Trie.get(depositTxns, keyb(t), Blob.equal)){
                        case(?(txn, ts)){ 
                            if (txn.status == #Failure){
                                depositTxns := Trie.remove(depositTxns, keyb(t), Blob.equal).0;
                            };
                        };
                        case(_){};
                    };
                };
                case(_){};
            };
        };
    };
    private func _putDepositTxn(_account: Account, _txHash: TxHash, _signature: [Nat8], _status: Status, _time: ?Timestamp, _error: ?Text) : (){ 
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        var claimingTime = Option.get(_time, _now());
        var confirmedTime: ?Timestamp = null;
        switch(_getDepositTxn(_txHash)){
            case(?(txn, ts)){ 
                claimingTime := txn.claimingTime; // first claiming time
                confirmedTime := txn.confirmedTime;
            };
            case(_){};
        };
        if (Option.isNull(confirmedTime)){ // txn.status != #Confirmed
            depositTxns := Trie.put<TxHashId, (DepositTxn, Timestamp)>(depositTxns, keyb(txHash), Blob.equal, ({
                txHash = _txHash;
                account = _account;
                signature = _signature;
                claimingTime = claimingTime;
                status = _status;
                transfer = null;
                confirmedTime = null;
                error = _error;
            }, _now())).0;
        };
    };
    private func _confirmDepositTxn(_txHash: TxHash, _status: Status, _transfer: ?Minter.TokenTxn, _confirmedTime: ?Timestamp, _error: ?Text) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(depositTxns, keyb(txHash), Blob.equal)){
            case(?(depositTxn, ts)){
                if (depositTxn.status != #Confirmed){
                    depositTxns := Trie.put<TxHashId, (DepositTxn, Timestamp)>(depositTxns, keyb(txHash), Blob.equal, ({
                        txHash = depositTxn.txHash;
                        account = depositTxn.account;
                        signature = depositTxn.signature;
                        claimingTime = depositTxn.claimingTime;
                        status = _status;
                        transfer = _transfer;
                        confirmedTime = _confirmedTime;
                        error = _error;
                    }, _now())).0;
                };
            };
            case(_){};
        };
    };
    private func _getDepositTxn(_txHash: TxHash) : ?(DepositTxn, Timestamp){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        return Trie.get(depositTxns, keyb(txHash), Blob.equal);
    };
    private func _isPendingTxn(_txHash: TxHash) : Bool{
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(depositTxns, keyb(txHash), Blob.equal)){
            case(?(item, ts)){ return item.status == #Pending; };
            case(_){ return false; };
        };
    };
    private func _isConfirmedTxn(_txHash: TxHash) : Bool{
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        var status: Status = #Unknown;
        switch(Trie.get(depositTxns, keyb(txHash), Blob.equal)){
            case(?(item, ts)){ status := item.status };
            case(_){};
        };
        return status == #Confirmed; 
    };

    private func _getGasLimit(_tokenId: EthAddress) : Nat{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        return tokenInfo.fee.gasLimit;
    };
    private func _getEthGas(_tokenId: EthAddress) : EthGas{
        let gasLimit = _getGasLimit(_tokenId);
        var maxFee = gasLimit * (ck_gasPrice/* + PRIORITY_FEE_PER_GAS*/);
        return { gasPrice = ck_gasPrice/* + PRIORITY_FEE_PER_GAS*/; gasLimit = gasLimit; maxFee = maxFee; };
    };
    private func _getFixedFee(_tokenId: EthAddress): CkFee{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        return {
            eth = tokenInfo.fee.fixedFee;
            token = tokenInfo.fee.fixedFee * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _getCkFee(_tokenId: EthAddress): CkFee{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let gas = _getEthGas(_tokenId); // ETH
        return {
            eth = gas.maxFee + tokenInfo.fee.fixedFee;
            token = (gas.maxFee + tokenInfo.fee.fixedFee) * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _getCkFeeForDepositing(_tokenId: EthAddress): CkFee{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let isERC20 = _tokenId != eth_;
        let gas = _getEthGas(_tokenId);
        var networkFee: Wei = 0;
        if (isERC20){
            networkFee := _getEthGas(eth_).maxFee;
        };
        return {
            eth = networkFee + gas.maxFee + tokenInfo.fee.fixedFee;
            token = (networkFee + gas.maxFee + tokenInfo.fee.fixedFee) * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _getCkFeeForDepositing2(_tokenId: EthAddress, _ethGas: EthGas): CkFee{
        let ethInfo = _getCkTokenInfo(eth_);
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let isERC20 = _tokenId != eth_;
        let gas = _ethGas;
        var networkFee: Wei = 0;
        if (isERC20){
            networkFee := _ethGas.gasPrice * ethInfo.fee.gasLimit;
        };
        return {
            eth = networkFee + gas.maxFee + tokenInfo.fee.fixedFee;
            token = (networkFee + gas.maxFee + tokenInfo.fee.fixedFee) * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _fetchPairPrice(_pairCanisterId: Principal): async* Float{
        let pair : ICDex.Self = actor(Principal.toText(_pairCanisterId));
        return (await pair.stats()).price * 0.98;
    };
    private func _getPairPrice(_tokenId: EthAddress): (Float, Timestamp){
        switch(Trie.get(tokens, keyt(_tokenId), Text.equal)){
            case(?(token)){
                switch(token.dexPrice){
                    case(?(price, ts)){ return (price, ts) };
                    case(_){ Prelude.unreachable() };
                };
            };
            case(_){ Prelude.unreachable() };
        };
    };
    private func _getEthRatio(_pairPrice: Float): Wei{
        let ethPrice = _getPairPrice(eth_).0;
        return _floatToNat(ethPrice / _pairPrice * _natToFloat(gwei_));
    };
    private func _putTokenDexPair(_tokenId: EthAddress, _dexPair: ?Principal): async* (){
        switch(Trie.get(tokens, keyt(_tokenId), Text.equal)){
            case(?(token)){
                let tokenInfo : TokenInfo = {
                    tokenId = token.tokenId;
                    std = token.std;
                    symbol = token.symbol;
                    decimals = token.decimals;
                    totalSupply = token.totalSupply;
                    minAmount = token.minAmount;
                    ckSymbol = token.ckSymbol;
                    ckLedgerId = token.ckLedgerId;
                    fee = token.fee;
                    dexPair = _dexPair;
                    dexPrice = token.dexPrice;
                };
                tokens := Trie.put(tokens, keyt(_tokenId), Text.equal, tokenInfo).0;
                ignore _putEvent(#config({setting = #setDexPair({token=_tokenId; dexPair=_dexPair;})}), ?_accountId(owner, null));
            };
            case(_){};
        };
    };
    private func _updateTokenPrice(_tokenId: EthAddress): async* (){
        switch(Trie.get(tokens, keyt(_tokenId), Text.equal)){
            case(?(token)){
                if (_now() >= Option.get(token.dexPrice, (0.0, 0)).1 + 90){
                    var price : Float = 0;
                    var ethRatio : Nat = 0;
                    if (_tokenId == quoteToken){
                        price := 1;
                        ethRatio := _getEthRatio(price);
                    };
                    if (_tokenId == eth_){
                        ethRatio := gwei_;
                    };
                    switch(token.dexPair){
                        case(?dexPair){
                            price := if (_tokenId == quoteToken) { price } else { await* _fetchPairPrice(dexPair) };
                            ethRatio := if (_tokenId == eth_) { ethRatio } else { _getEthRatio(price) };
                        };
                        case(_){};
                    };
                    if (ethRatio > 0){
                        let tokenInfo : TokenInfo = {
                            tokenId = token.tokenId;
                            std = token.std;
                            symbol = token.symbol;
                            decimals = token.decimals;
                            totalSupply = token.totalSupply;
                            minAmount = token.minAmount;
                            ckSymbol = token.ckSymbol;
                            ckLedgerId = token.ckLedgerId;
                            fee = {
                                fixedFee = token.fee.fixedFee;
                                gasLimit = token.fee.gasLimit;
                                ethRatio = ethRatio;
                            };
                            dexPair = token.dexPair;
                            dexPrice = ?(price, _now());
                        };
                        tokens := Trie.put(tokens, keyt(_tokenId), Text.equal, tokenInfo).0;
                        ignore _putEvent(#updateTokenPrice({token = _tokenId; price = price; ethRatio = ethRatio}), ?_accountId(Principal.fromActor(this), null));
                    };
                };
            };
            case(_){};
        };
    }; 
    private func _updateTokenEthRatio(): async* (){
        if (_now() >= lastUpdateTokenPriceTime + getTokenPriceIntervalSeconds){
            lastUpdateTokenPriceTime := _now();
            await* _updateTokenPrice(eth_);
            for ((tokenId, token) in Trie.iter(tokens)){
                if (tokenId != eth_){
                    try{
                        await* _updateTokenPrice(tokenId);
                    }catch(e){
                        if (app_debug) { throw Error.reject(Error.message(e)) };
                    };
                };
            };
        }
    }; 
    private func _feeSwap(_tokenId: EthAddress, _ckToken: Principal, _dexPair: Principal): async* (){
        let feeTempAccount = {owner = Principal.fromActor(this); subaccount = ?sa_two};
        let icrc1: ICRC1.Self = actor(Principal.toText(_ckToken));
        let pair: ICDex.Self = actor(Principal.toText(_dexPair));
        let ckTokenFee = await icrc1.icrc1_fee();
        let tradeBlance = await icrc1.icrc1_balance_of({owner = feeTempAccount.owner; subaccount = _toSaBlob(feeTempAccount.subaccount)});
        if (tradeBlance > ckTokenFee*2){
            let tradeAmount = Nat.sub(tradeBlance, ckTokenFee);
            let prepares = await pair.getTxAccount(Tools.principalToAccountHex(feeTempAccount.owner, feeTempAccount.subaccount));
            let tx_icrc1Account = prepares.0;
            switch(await* _sendCkToken2(_tokenId, Blob.fromArray(sa_two), tx_icrc1Account, tradeAmount)){
                case(#Ok(blockNum)){
                    switch(await pair.tradeMKT(_ckToken, tradeAmount, null, ?sa_two, ?Text.encodeUtf8("Fee conversion"))){
                        case(#ok(res)){};
                        case(#err(e)){};
                    };
                };
                case(#Err(e)){};
            };
        };
    };
    private func _convertFees(): async* (){
        let mainAccount: Account = {owner = Principal.fromActor(this); subaccount = null};
        let feeAccount: Account = {owner = Principal.fromActor(this); subaccount = ?sa_one};
        let feeTempAccount: Account = {owner = Principal.fromActor(this); subaccount = ?sa_two};
        let eth = _getCkTokenInfo(eth_);
        let quote = _getCkTokenInfo(quoteToken);
        if (_now() >= lastConvertFeesTime + convertFeesIntervalSeconds){
            lastConvertFeesTime := _now();
            let ethGas = _getEthGas(eth_);
            for ((blobTokenId, balance) in Trie.iter(feeBalances)){
                let tokenId = ABI.toHex(Blob.toArray(blobTokenId));
                if (tokenId == quoteToken){
                    // tranfer icUSDT to feeTempAccount
                    let token = _getCkTokenInfo(tokenId);
                    try{
                        let icrc1: ICRC1.Self = actor(Principal.toText(token.ckLedgerId));
                        let ckTokenFee = await icrc1.icrc1_fee();
                        if (balance > ckTokenFee*10){
                            let amount = Nat.sub(balance, ckTokenFee);
                            switch(await* _sendCkToken2(tokenId, Blob.fromArray(sa_one), {owner = feeTempAccount.owner; subaccount = _toSaBlob(feeTempAccount.subaccount)}, amount)){
                                case(#Ok(blockNum)){
                                    let mainFeeBalance = _getFeeBalance(tokenId);
                                    ignore _subFeeBalance(tokenId, Nat.min(mainFeeBalance, balance));
                                    ignore _addBalance(mainAccount, tokenId, amount);
                                };
                                case(#Err(e)){};
                            };
                        };
                    }catch(e){
                        if (app_debug) { throw Error.reject(Error.message(e)) };
                    };
                }else if (tokenId != eth_ and tokenId != quoteToken){
                    let token = _getCkTokenInfo(tokenId);
                    let minBalance = ethGas.maxFee * token.fee.ethRatio / gwei_ * (if (app_debug) {10} else {100});
                    if (balance >= minBalance){
                        switch(token.dexPair){
                            case(?(dexPair)){
                                try{
                                    let icrc1: ICRC1.Self = actor(Principal.toText(token.ckLedgerId));
                                    // let pair: ICDex.Self = actor(Principal.toText(dexPair));
                                    let ckTokenFee = await icrc1.icrc1_fee();
                                    if (balance > ckTokenFee*10){
                                        let amount = Nat.sub(balance, ckTokenFee);
                                        // tranfer fee to feeTempAccount
                                        switch(await* _sendCkToken2(tokenId, Blob.fromArray(sa_one), {owner = feeTempAccount.owner; subaccount = _toSaBlob(feeTempAccount.subaccount)}, amount)){
                                            case(#Ok(blockNum)){
                                                let mainFeeBalance = _getFeeBalance(tokenId);
                                                ignore _subFeeBalance(tokenId, Nat.min(mainFeeBalance, balance));
                                                    ignore _addBalance(mainAccount, tokenId, amount);
                                            };
                                            case(#Err(e)){};
                                        };
                                        // icERC20 -> icUSDT
                                        await* _feeSwap(tokenId, token.ckLedgerId, dexPair);
                                    };
                                }catch(e){
                                    if (app_debug) { throw Error.reject(Error.message(e)) };
                                };
                            };
                            case(_){};
                        };
                    };
                };
            };
            // icUSDT -> icETH
            switch(eth.dexPair){
                case(?(dexPair)){
                    try{
                        await* _feeSwap(quoteToken, quote.ckLedgerId, dexPair);
                    }catch(e){
                        if (app_debug) { throw Error.reject(Error.message(e)) };
                    };
                };
                case(_){};
            };
            // transfer icETH to feeAccount
            let icrc1: ICRC1.Self = actor(Principal.toText(eth.ckLedgerId));
            let ckTokenFee = await icrc1.icrc1_fee();
            let feeBalance = await icrc1.icrc1_balance_of({owner = feeTempAccount.owner; subaccount = _toSaBlob(feeTempAccount.subaccount)});
            if (feeBalance > ckTokenFee*2){
                let feeAmount = Nat.sub(feeBalance, ckTokenFee);
                switch(await* _sendCkToken2(eth_, Blob.fromArray(sa_two), {owner = feeAccount.owner; subaccount = _toSaBlob(feeAccount.subaccount)}, feeAmount)){
                    case(#Ok(blockNum)){
                        let mainBalance = _getBalance(mainAccount, eth_);
                        ignore _subBalance(mainAccount, eth_, Nat.min(mainBalance, feeBalance));
                        ignore _addFeeBalance(eth_, feeAmount);
                    };
                    case(#Err(e)){};
                };
            };
        }
    };
    private func _getMinterBalance(_token: ?EthAddress, _enPause: Bool) : async* Minter.BalanceStats{
        let tokenId = _toLower(Option.get(_token, eth_));
        let mainAccount: Account = {owner = Principal.fromActor(this); subaccount = null };
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(mainAccount.owner, mainAccount.subaccount));
        let nativeBalance = await* _fetchBalance(tokenId, mainAddress, true);
        let ckLedger = _getCkLedger(tokenId);
        let ckTotalSupply = await ckLedger.icrc1_total_supply();
        let ckFeetoBalance = await ckLedger.icrc1_balance_of({owner = Principal.fromActor(this); subaccount = _toSaBlob(?sa_one) });
        let minterBalance = _getBalance(mainAccount, tokenId);
        if (_enPause and _ictcAllDone()
        and (nativeBalance < Nat.sub(ckTotalSupply, ckFeetoBalance) * 98 / 100 or nativeBalance < minterBalance * 95 / 100)){ /*config*/
            paused := true;
            ignore _putEvent(#suspend({message = ?"The pool account balance does not match and the system is suspended and pending DAO processing."}), ?_accountId(Principal.fromActor(this), null));
        };
        return {nativeBalance = nativeBalance; totalSupply = ckTotalSupply; minterBalance = minterBalance; feeBalance = ckFeetoBalance};
    };
    private func _reconciliation() : async* (){
        _checkICTCError();
        for ((tokenId, tokenInfo) in Trie.iter(tokens)){
            ignore await* _getMinterBalance(?tokenId, true);
        };
    };

    private func _getTx(_txi: TxIndex) : ?Minter.TxStatus{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){ return ?tx; };
            case(_){ return null; };
        };
    };
    private func _newTx(_type: {#Deposit; #DepositGas; #Withdraw}, _account: Account, _tokenId: EthAddress, _from: EthAddress, _to: EthAddress, _amount: Wei, _fee: { gasPrice: Wei; gasLimit: Nat; maxFee: Wei;}) : TxIndex{
        let txStatus: Minter.TxStatus = {
            txType = _type;
            tokenId = _tokenId;
            account = _account;
            from = _from;
            to = _to;
            amount = _amount;
            fee = _fee;
            nonce = null;
            toids = [];
            txHash = [];
            tx = null;
            rawTx = null;
            signedTx = null;
            receipt = null;
            rpcRequestId = null;
            kytRequestId = null;
            status = #Building;
        };
        transactions := Trie.put(transactions, keyn(txIndex), Nat.equal, (txStatus, _now(), ?_now())).0;
        txIndex += 1;
        return Nat.sub(txIndex, 1);
    };
    private func _updateTx(_txIndex: TxIndex, _update: Minter.UpdateTxArgs, _coveredTime: ?Timestamp) : (){
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                var toids = tx.toids;
                let updateToids = Option.get(_update.toids, []);
                for (toid in updateToids.vals()){
                    if (Option.isNull(Array.find(toids, func (t: Nat): Bool{ t == toid }))){
                        toids := Tools.arrayAppend(toids, [toid]);
                    };
                };
                let txStatus: Minter.TxStatus = {
                    txType = tx.txType;
                    tokenId = tx.tokenId;
                    account = tx.account;
                    from = tx.from;
                    to = tx.to;
                    amount = Option.get(_update.amount, tx.amount);
                    fee = Option.get(_update.fee, tx.fee);
                    nonce = switch(_update.nonce){case(?(nonce)){ ?nonce }; case(_){ tx.nonce } };
                    toids = toids;
                    txHash = switch(_update.txHash){case(?(txHash)){ Tools.arrayAppend(tx.txHash, [txHash]) }; case(_){ tx.txHash } };
                    tx = switch(_update.tx){case(?(tx)){ ?tx }; case(_){ tx.tx } };
                    rawTx = switch(_update.rawTx){case(?(rawTx)){ ?rawTx }; case(_){ tx.rawTx } };
                    signedTx = switch(_update.signedTx){case(?(signedTx)){ ?signedTx }; case(_){ tx.signedTx } };
                    receipt = switch(_update.receipt){case(?(receipt)){ ?receipt }; case(_){ tx.receipt } };
                    rpcRequestId = switch(_update.rpcRequestId){case(?(requestId)){ ?requestId }; case(_){ tx.rpcRequestId } };
                    kytRequestId = switch(_update.kytRequestId){case(?(kytRequestId)){ ?kytRequestId }; case(_){ tx.kytRequestId } };
                    status = Option.get(_update.status, tx.status);
                };
                // ts: The time at which txn is broadcast. If the txn is not confirmed/failed within the expected time, the ts will be updated to a new time.
                let txTs: Timestamp = Option.get(_update.ts, ts);
                // coveredTs: The time recorded when a txn is replaced.
                let txCoverTs: ?Timestamp = if (Option.isSome(_coveredTime)){ _coveredTime }else{ cts };
                transactions := Trie.put(transactions, keyn(_txIndex), Nat.equal, (txStatus, txTs, txCoverTs)).0;
            };
            case(_){};
        };
    };
    private func _updateTxToids(_txi: TxIndex, _toids: [Nat]) : (){
        _updateTx(_txi, {
            fee = null;
            amount = null;
            nonce = null;
            toids = ?_toids;
            txHash = null;
            tx = null;
            rawTx = null;
            signedTx = null;
            receipt = null;
            rpcRequestId = null;
            kytRequestId = null;
            status = null;
            ts = null;
        }, null);
    };
    private func _ictcCoverTx(_txi: TxIndex, _resetNonce: Bool, _amount: Nat, _networkFee: EthGas, _originalTx: Minter.TxStatus, _feeDiffEth: Nat) : (TxIndex, SagaTM.Toid){
        let tx = _originalTx;
        let feeDiffEth = _feeDiffEth;
        let accountId = _accountId(tx.account.owner, tx.account.subaccount);
        let isERC20 = tx.tokenId != eth_;
        let networkFee = _networkFee; // for ETH 
        var preTids: [Nat] = [];
        let saga = _getSaga();
        if (feeDiffEth > 0 and tx.txType == #Deposit and isERC20){
            let (userAddress, userNonce) = _getEthAddressQuery(accountId);
            let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
            let txi0 = _newTx(#DepositGas, tx.account, eth_, mainAddress, userAddress, feeDiffEth, networkFee);
            let txi0Blob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi0))); 
            let toid0 : Nat = saga.create("deposit_gas_for_covering", #Forward, ?txi0Blob, null);
            let task0_1 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#getNonce(txi0, ?[toid0])), [], 0, null, null);
            let _ttid0_1 = saga.push(toid0, task0_1, null, null);
            let task0_2 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#createTx(txi0)), [], 0, null, null);
            let _ttid0_2 = saga.push(toid0, task0_2, null, null);
            let task0_3 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#signTx(txi0)), [], 0, null, null);
            let _ttid0_3 = saga.push(toid0, task0_3, null, null);
            let task0_4 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#sendTx(txi0)), [], 0, null, null);
            let _ttid0_4 = saga.push(toid0, task0_4, null, null);
            let task0_5 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#syncTx(txi0, true)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
            let ttid0_5 = saga.push(toid0, task0_5, null, null);
            preTids := [ttid0_5];
            saga.close(toid0);
            _updateTxToids(txi0, [toid0]);
            ignore _putEvent(#depositGas({txIndex = txi0; toid = toid0; account = tx.account; address = userAddress; amount = feeDiffEth}), ?accountId);
        };
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        let toid : Nat = saga.create("cover_transaction", #Forward, ?txiBlob, null);
        if (_resetNonce){
            let task0 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#getNonce(_txi, ?[toid])), preTids, 0, null, null);
            let _ttid0 = saga.push(toid, task0, null, null);
            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(_txi)), [], 0, null, null);
            let _ttid1 = saga.push(toid, task1, null, null);
        }else{
            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(_txi)), preTids, 0, null, null);
            let _ttid1 = saga.push(toid, task1, null, null);
        };
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(_txi)), [], 0, null, null);
        let _ttid2 = saga.push(toid, task2, null, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(_txi)), [], 0, null, null);
        let _ttid3 = saga.push(toid, task3, null, null);
        let task_4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(_txi, false)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let _ttid_4 = saga.push(toid, task_4, null, null);
        saga.close(toid);
        // _updateTxToids(_txi, [toid]);
        return (_txi, toid);
    };
    private func _coverTx(_txi: TxIndex, _resetNonce: Bool, _refetchGasPrice: ?Bool, _amountSub: Wei, _autoAdjustAmount: Bool, _doneAllTO: Bool) : async* ?BlockHeight{
        if (Option.get(_refetchGasPrice, false) or _now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            ignore await* _fetchGasPrice();
        };
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status != #Failure and tx.status != #Confirmed){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    let isERC20 = tx.tokenId != eth_;
                    let networkFee = _getEthGas(eth_); // for ETH 
                    let feeNew = _getEthGas(tx.tokenId); 
                    var amountNew = Nat.sub(tx.amount, _amountSub);
                    if (Option.isNull(tx.nonce) and not(_resetNonce)){
                        throw Error.reject("402: Nonce is empty!");
                    };
                    // check ICTC in progress
                    for (toid in tx.toids.vals()){
                        if (_onlyBlocking(toid) and _doneAllTO){
                            let _r = await* _getSaga().done(toid, #Recovered, true);
                        }else if (_onlyBlocking(toid)){
                            let _r = await* _getSaga().complete(toid, #Recovered);
                        };
                    };
                    if (not(_ictcDone(tx.toids))){
                        throw Error.reject("402: ICTC has orders in progress!");
                    };
                    // Adjust amount
                    var feeDiffEth: Nat = 0;
                    var feeDiff: Nat = 0;
                    if (_autoAdjustAmount and feeNew.maxFee > tx.fee.maxFee){
                        let tokenInfo = _getCkTokenInfo(tx.tokenId);
                        if (isERC20){
                            feeDiffEth := Nat.sub(feeNew.maxFee, tx.fee.maxFee);
                            // feeDiff := 0; // feeDiffEth * tokenInfo.fee.ethRatio / gwei_;
                            if (tx.txType == #Withdraw){
                                feeDiff := feeDiffEth * tokenInfo.fee.ethRatio / gwei_;
                            };
                        }else{
                            feeDiffEth := Nat.sub(feeNew.maxFee, tx.fee.maxFee);
                            feeDiff := feeDiffEth;
                        };
                    };
                    if (amountNew > feeDiff){
                        amountNew -= feeDiff;
                        if (tx.txType == #Withdraw and isERC20){
                            let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                            ignore _addFeeBalance(tx.tokenId, feeDiff);
                            ignore _mintCkToken(tx.tokenId, feeAccount, feeDiff, ?_txi, ?"mint_ck_token(fee)");
                            let mainFeeBalance = _getFeeBalance(eth_);
                            ignore _subFeeBalance(eth_, Nat.min(mainFeeBalance, feeDiffEth));
                            ignore _burnCkToken(eth_, Blob.fromArray(sa_one), feeDiffEth, feeAccount, ?"burn_ck_token(fee)");
                        };
                        let (txi, toid) = _ictcCoverTx(_txi, _resetNonce, amountNew, networkFee, tx, feeDiffEth);
                        let args: Minter.UpdateTxArgs = {
                            fee = ?feeNew;
                            amount = ?amountNew;
                            nonce = null;
                            toids = ?[toid];
                            txHash = null;
                            tx = null;
                            rawTx = null;
                            signedTx = null;
                            receipt = null;
                            rpcRequestId = null;
                            kytRequestId = null;
                            status = ?#Building;
                            ts = ?_now();
                        };
                        _updateTx(_txi, args, ?_now());
                        await* _ictcSagaRun(toid, false);
                        // record event
                        return ?_putEvent(#coverTransaction({txIndex = _txi; toid = toid; account = tx.account; preTxid=tx.txHash; updateTx = ?args}), ?accountId);
                    }else{
                        throw Error.reject("402: Insufficient amount!");
                    };
                }else{
                    throw Error.reject("402: The status of transaction is completed!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _putWithdrawal(_a: AccountId, _txi: TxIndex) : (){
        switch(Trie.get(withdrawals, keyb(_a), Blob.equal)){
            case(?(list)){
                var temp = list;
                if (List.size(list) >= 1000){
                    temp := List.pop(temp).1;
                };
                withdrawals := Trie.put(withdrawals, keyb(_a), Blob.equal, List.push(_txi, temp)).0;
            };
            case(_){
                withdrawals := Trie.put(withdrawals, keyb(_a), Blob.equal, List.push(_txi, null)).0;
            };
        };
    };
    private func _stats(_token: EthAddress, _type: {#Minting;#Retrieval}, _amount: Wei) : (){
        let token = _getCkTokenInfo(_token);
        var ratio = _floatToNat(Option.get(token.dexPrice, (0.0, 0)).0 * _natToFloat(gwei_));
        switch(_type){
            case(#Minting){
                countMinting += 1;
                totalMinting += if (ratio > 0){ _amount * gwei_ / ratio }else{ 0 }; //token.fee.ethRatio;
            };
            case(#Retrieval){
                countRetrieval += 1;
                totalRetrieval += if (ratio > 0){ _amount * gwei_ / ratio }else{ 0 }; //token.fee.ethRatio;
            };
        };
    };

    private func _fetchAccountAddress(_dpath: DerivationPath) : async* (pubkey:PubKey, ethAccount:EthAccount, address: EthAddress){
        var own_public_key : [Nat8] = [];
        var own_account : [Nat8] = [];
        var own_address : Text = "";
        let ecdsa_public_key = await ic.ecdsa_public_key({
            canister_id = null;
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = KEY_NAME }; //dfx_test_key
        });
        own_public_key := Blob.toArray(ecdsa_public_key.public_key);
        switch(ETHCrypto.pubToAddress(own_public_key)){
            case(#ok(address)){
                own_address := address;
                own_account := Option.get(ABI.fromHex(own_address), []);
            };
            case(#err(e)){
                throw Error.reject("401: Error while getting address!");
            };
        };
        return (own_public_key, own_account, own_address);
    };
    private func _sign(_dpath: DerivationPath, _messageHash : [Nat8]) : async* [Nat8] {
        return await* ETHCrypto.signMsg(_dpath, _messageHash, ECDSA_SIGN_CYCLES, KEY_NAME);
    };


    private func _isNormalRpcReturn(_msg: Text) : Bool{
        return Text.contains(_msg, #text "no consensus was reached") or Text.contains(_msg, #text "No consensus could be reached") 
        or Text.contains(_msg, #text "already known") or Text.contains(_msg, #text "ALREADY_EXISTS");
    };
    public query func rpc_call_transform(raw : IC.TransformArgs) : async IC.HttpResponsePayload {
        return RpcCaller.transform(raw);
    };
    private func _fetchEthCall(_rpcUrl: Text, _methodName: Text, _params: Text, _responseSize: Nat64, _requestId: Nat): async* (Nat, Minter.RPCResult){
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\""# _methodName #"\",\"params\": "# _params #",\"id\":"# Nat.toText(id) #"}";
        rpcId += 1;
        ck_rpcLogs := RpcRequest.preRpcLog(ck_rpcLogs, id, _rpcUrl, input);
        Cycles.add<system>(RPC_AGENT_CYCLES);
        try{
            let res = await* RpcCaller.call(_rpcUrl, input, _responseSize, RPC_AGENT_CYCLES, ?{function = rpc_call_transform; context = Blob.fromArray([])});
            return (id, #Ok(res.2));
        }catch(e){
            return (id, #Err(Error.message(e)));
        };
    };
    private func _fetchValues(_methodName: Text, _params: Text, _responseSize: Nat64, _minRpcRequests: Nat, _paths: [({#String;#Value;#Bytes}, Text)]): async* (data: [Value], jsons: [Text]){
        let minConfirmationNum : Nat = _minRpcRequests;
        var jsons: [Text] = [];
        func _request(keeper: AccountId, rpcUrl: Text, requestId: Nat): async* RpcFetchLog{
            var logId : RpcId = 0;
            var result: Text = "";
            var values: [Value] = [];
            var error: Text = "";
            var status: RpcRequestStatus = #pending; // {#pending; #ok: [Value]; #err: Text};
            try{
                logId := rpcId;
                let (id, res) = await* _fetchEthCall(rpcUrl, _methodName, _params, _responseSize, requestId);
                logId := id;
                switch(res){
                    case(#Ok(r)){
                        result := r;
                        jsons := Tools.arrayAppend(jsons, [r]);
                        var x: Nat = 0;
                        for ((valueType, path) in _paths.vals()){
                            x += 1;
                            switch(valueType){
                                case(#String){
                                    switch(ETHCrypto.getStringFromJson(r, path)){
                                        case(?(value)){ values := Tools.arrayAppend(values, [#Text(ETHCrypto.trimQuote(value))]); }; 
                                        case(_){ 
                                            values := Tools.arrayAppend(values, [#Empty]); 
                                            error #= " Error while fetching data of No. "# Nat.toText(x) #".";
                                        };
                                    };
                                };
                                case(#Value){
                                    switch(ETHCrypto.getValueFromJson(r, path)){
                                        case(?(value)){ values := Tools.arrayAppend(values, [#Nat(value)]); }; 
                                        case(_){ 
                                            values := Tools.arrayAppend(values, [#Empty]); 
                                            error #= " Error while fetching data of No. "# Nat.toText(x) #".";
                                        };
                                    };
                                };
                                case(#Bytes){
                                    switch(ETHCrypto.getBytesFromJson(r, path)){
                                        case(?(value)){ values := Tools.arrayAppend(values, [#Raw(value)]); }; 
                                        case(_){ 
                                            values := Tools.arrayAppend(values, [#Empty]); 
                                            error #= " Error while fetching data of No. "# Nat.toText(x) #".";
                                        };
                                    };
                                };
                            };
                        };
                        ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, ?r, ?error);
                        if (error.size() == 0){
                            status := #ok(values);
                        }else{
                            switch(ETHCrypto.getStringFromJson(r, "error/message")){
                                case(?(value)){
                                    throw Error.reject("Returns error: "# value # "." # error);
                                }; 
                                case(_){
                                    throw Error.reject("Error in parsing json." # error);
                                };
                            };
                        };
                    };
                    case(#Err(e)){
                        ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, null, ?e);
                        throw Error.reject(e);
                    };
                };
                ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true);
            }catch(e){
                error := Error.message(e);
                if (Text.contains(error, #text "Returns error:")){ 
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true);
                }else{
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, false);
                };
                status := #err(error);
            };
            return { id = logId; result = result; status = status; keeper = keeper; time = _now(); };
        };
        let offset = _now() % 100;
        let (keeper, rpcUrl, size) = _getRpcUrl(offset);
        let requestId = rpcRequestId;
        rpcRequestId += 1;
        var isConfirmed : Bool = false;
        var i : Nat = 0;
        var requestStatus: RpcRequestStatus = #pending;
        while(not(isConfirmed) and i < size + 2){
            let (keeper, rpcUrl, size_) = _getRpcUrl(offset + RpcRequest.threeSegIndex(i, size));
            i += 1;
            let log = await* _request(keeper, rpcUrl, requestId);
            let (data1, data2, status_) = RpcRequest.putRpcRequestLog(ck_rpcRequests, ck_rpcRequestConsensusTemps, requestId, log, minConfirmationNum);
            ck_rpcRequests := data1;
            ck_rpcRequestConsensusTemps := data2;
            requestStatus := status_;
            switch(requestStatus){
                case(#ok(v)){ isConfirmed := true };
                case(_){};
            };
        };
        switch(requestStatus){
            case(#ok(v)){
                return (v, jsons);
            };
            case(#err(e)){
                throw Error.reject("RequestId "# Nat.toText(requestId) #": "#e);
            };
            case(#pending){
                throw Error.reject("RequestId "# Nat.toText(requestId) #": No consensus on RPC data: minimum number of confirmations not reached");
            };
        };
    };
    private func _fetchNumber(_methodName: Text, _params: Text, _responseSize: Nat64, _minRpcRequests: Nat, _path: Text): async* Nat{
        let (values, jsons) = await* _fetchValues(_methodName, _params, _responseSize, _minRpcRequests, [(#Value, _path)]);
        switch(values[0]){ 
            case(#Nat(n)){ return n; }; 
            case(_){ throw Error.reject("`_fetchNumber()` Error."); }
        };
    };
    private func _fetchString(_methodName: Text, _params: Text, _responseSize: Nat64, _minRpcRequests: Nat, _path: Text): async* Text{
        let (values, jsons) = await* _fetchValues(_methodName, _params, _responseSize, _minRpcRequests, [(#String, _path)]);
        switch(values[0]){ 
            case(#Text(t)){ return ETHCrypto.trimQuote(t); }; 
            case(_){ throw Error.reject("`_fetchString()` Error."); }
        };
    };
    private func _fetchChainId() : async* Nat {
        let params = "[]";
        ck_chainId := await* _fetchNumber("eth_chainId", params, 1000, minRpcConfirmations, "result");
        return ck_chainId;
    };
    // The reason minRpcRequests is set to 2 is that getting the wrong gasPrice does not cause fund to be lost.
    private func _fetchGasPrice() : async* Nat {
        let params = "[]";
        let value1 = await* _fetchNumber("eth_gasPrice", params, 1000, 1, "result");
        let value2 = await* _fetchNumber("eth_gasPrice", params, 1000, 1, "result");
        ck_gasPrice := (value1 + value2) / 2 * 115 / 100 + 100000000; 
        lastGetGasPriceTime := _now();
        return ck_gasPrice;
    };
    private func _fetchBlockNumber() : async* Nat{
        let minRpcRequests : Nat = Nat.max(2, minRpcConfirmations);
        let params = "[]";
        var value: Nat = 0;
        var confirmations: Nat = 0;
        var i: Nat = 0;
        while (confirmations < minRpcRequests and i < minRpcRequests * 2){
            try{
                let v = await* _fetchNumber("eth_blockNumber", params, 1000, 1, "result");
                if (value == 0){
                    value := v;
                    confirmations += 1;
                }else if (v >= Nat.sub(value, 1) and v <= value + 3){
                    value := Nat.max(value, v);
                    confirmations += 1;
                };
            }catch(e){};
            i += 1;
        };
        if (value >= ck_ethBlockNumber.0 and confirmations >= minRpcRequests){
            ck_ethBlockNumber := (value, _now());
        }else{
            throw Error.reject("BlockNumber is wrong!");
        };
        return ck_ethBlockNumber.0;
    };
    private func _fetchAccountNonce(_address: EthAddress, _blockNumber:{#latest; #pending;}) : async* Nonce{
        let minRpcRequests : Nat = minRpcConfirmations;
        var blockNumber: Text = ABI.natToHex(Nat.sub(_getBlockNumber(), minConfirmations));
        switch(_blockNumber){
            case(#latest){ blockNumber := "latest" };
            case(#pending){ blockNumber := "pending" };
        };
        let params = "[\""# _address #"\", \""# blockNumber #"\"]";
        return await* _fetchNumber("eth_getTransactionCount", params, 1000, minRpcRequests, "result");
    };
    private func _fetchEthBalance(_address : EthAddress, _latest: Bool): async* Wei{
        let minRpcRequests : Nat = minRpcConfirmations;
        let blockNumber: Text = if (_latest) { "latest" } else { ABI.natToHex(Nat.sub(_getBlockNumber(), minConfirmations)) };
        let params = "[\""# _address #"\", \""# blockNumber #"\"]";
        return await* _fetchNumber("eth_getBalance", params, 1000, minRpcRequests, "result");
    };
    private func _fetchERC20Balance(_tokenId: EthAddress, _address : EthAddress, _latest: Bool): async* Wei{
        let minRpcRequests : Nat = minRpcConfirmations;
        let blockNumber: Text = if (_latest) { "latest" } else { ABI.natToHex(Nat.sub(_getBlockNumber(), minConfirmations)) };
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = await* _getEthAddress(mainAccoundId, false);
        let args = ABI.toHex(ABI.encodeErc20BalanceOf(_address));
        let params = "[{"# 
            "\"from\": \""# mainAddress #"\"," # 
            "\"to\": \""# _tokenId #"\"," #
            "\"data\": \""# args #"\"" # 
        "}, \""# blockNumber #"\"]";
        return await* _fetchNumber("eth_call", params, 1000, minRpcRequests, "result");
    };
    private func _fetchBalance(_tokenId: EthAddress, _address : EthAddress, _latest: Bool): async* Wei{
        if (_tokenId == eth_){
            return await* _fetchEthBalance(_address, _latest);
        }else{
            return await* _fetchERC20Balance(_tokenId, _address, _latest);
        };
    };
    private func _sendRawTx(_raw: [Nat8]) : async* (requestId: RpcRequestId, Result.Result<TxHash, Text>){
        let _methodName = "eth_sendRawTransaction";
        let _params = "[\""# ABI.toHex(_raw) #"\"]";
        let _responseSize: Nat64 = 1000;
        let _jsonPath = "result";
        let minRpcRequests : Nat = 1;
        var possibleResult: Text = "";
        func _request(keeper: AccountId, rpcUrl: Text, requestId: Nat): async* RpcFetchLog{
            var logId : RpcId = 0;
            var result: Text = "";
            var values: [Value] = [];
            var error: Text = "";
            var status: RpcRequestStatus = #pending; // {#pending; #ok: [Value]; #err: Text};
            try{
                logId := rpcId;
                let (id, res) = await* _fetchEthCall(rpcUrl, _methodName, _params, _responseSize, requestId);
                logId := id;
                switch(res){
                    case(#Ok(r)){
                        result := r;
                        switch(ETHCrypto.getBytesFromJson(r, _jsonPath)){ //*
                            case(?(value)){ 
                                ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, ?r, null);
                                values := [#Raw(value)];
                                status := #ok(values);
                                possibleResult := ABI.toHex(value); //*
                            }; 
                            case(_){
                                switch(ETHCrypto.getStringFromJson(r, "error/message")){
                                    case(?(value)){ 
                                        ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, null, ?("Returns error: "# value));
                                        throw Error.reject("Returns error: "# value);
                                    }; 
                                    case(_){
                                        ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, null, ?"Error in parsing json");
                                        throw Error.reject("Error in parsing json");
                                    };
                                };
                            };
                        };
                    };
                    case(#Err(e)){ //*
                        ck_rpcLogs := RpcRequest.postRpcLog(ck_rpcLogs, id, null, ?e);
                        throw Error.reject(e);
                    };
                };
                ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true);
            }catch(e){
                error := Error.message(e);
                if (_isNormalRpcReturn(error)){ 
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true);
                    values := [#Text(error)];
                    status := #ok(values);
                    if (possibleResult.size() == 0){
                        possibleResult := error;
                    };
                }else if (Text.contains(error, #text "nonce too low")){ 
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true); // Not rpc node failure
                    status := #err("Not sure if it has been successful: " # error);
                }else if (Text.contains(error, #text "Returns error:")){ 
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, true); 
                    status := #err(error);
                }else{
                    ck_rpcProviders := RpcRequest.updateRpcProviderStats(ck_rpcProviders, healthinessIntervalSeconds, keeper, false);
                    status := #err(error);
                };
            };
            return { id = logId; result = result; status = status; keeper = keeper; time = _now(); };
        };
        let offset = Int.abs(Time.now()) % 100;
        let (keeper, rpcUrl, size) = _getRpcUrl(offset);
        let requestId = rpcRequestId;
        rpcRequestId += 1;
        var isConfirmed : Bool = false;
        var i : Nat = 0;
        var requestStatus: RpcRequestStatus = #pending;
        while(not(isConfirmed) and i < size + 2){
            let (keeper, rpcUrl, size_) = _getRpcUrl(offset + RpcRequest.threeSegIndex(i, size));
            i += 1;
            let log = await* _request(keeper, rpcUrl, requestId);
            let (data1, data2, status_) = RpcRequest.putRpcRequestLog(ck_rpcRequests, ck_rpcRequestConsensusTemps, requestId, log, minRpcRequests);
            ck_rpcRequests := data1;
            ck_rpcRequestConsensusTemps := data2;
            requestStatus := status_;
            switch(requestStatus){
                case(#ok(v)){ isConfirmed := true };
                case(_){};
            };
            if (possibleResult.size() > 0){ //*
                isConfirmed := true;
            };
        };
        // Consensus was reached:
        switch(requestStatus){
            case(#ok(v)){
                switch(v[0]){ 
                    case(#Raw(txh)){ return (requestId, #ok(ABI.toHex(txh))); }; 
                    case(#Text(msg)){ return (requestId, #err(msg)); }; 
                    case(_){}
                };
            };
            case(#err(e)){};
            case(#pending){};
        };
        // No consensus was reached:
        if (possibleResult.size() > 0){ 
            return (requestId, #err(possibleResult));
        }else{
            throw Error.reject("RPC requestId "# Nat.toText(requestId) #": Error.");
        };
    };
    private func _fetchTxn(_txHash: TxHash): async* (success: Bool, txn: ?Minter.TokenTxn, height: BlockHeight, confirmation: Status, nonce: ?Nat, returns: ?[Text]){
        let minRpcRequests : Nat = minRpcConfirmations;
        try{
            let params = "[\""# _txHash #"\"]";
            let (res, jsons) = await* _fetchValues("eth_getTransactionByHash", params, 2500, minRpcRequests, 
            [(#Value, "result/blockNumber"), (#String, "result/from"), (#String, "result/to"), (#Value, "result/value"), (#Bytes, "result/input"), (#Value, "result/nonce")]);
            var token: EthAddress = eth_;
            var blockNumber : Nat = switch(res[0]){ case(#Nat(v)){ v }; case(_){ 0 } };
            var from : Text = switch(res[1]){ case(#Text(v)){ ETHCrypto.trimQuote(v) }; case(_){ "" } };
            var to : Text = switch(res[2]){ case(#Text(v)){ ETHCrypto.trimQuote(v) }; case(_){ "" } };
            var value : Nat = switch(res[3]){ case(#Nat(v)){ v }; case(_){ 0 } };
            var input : [Nat8] = switch(res[4]){ case(#Raw(v)){ v }; case(_){ [] } };
            // var returns : ?Text = switch(res[5]){ case(#Text(v)){ ?v }; case(_){ null } };
            var nonce : ?Nat = switch(res[5]){ case(#Nat(v)){ ?v }; case(_){ null } };
            var confirmation: Status = #Unknown;

            if (_getBlockNumber() >= blockNumber + minConfirmations){
                confirmation := #Confirmed;
            }else if (blockNumber > 0){
                confirmation := #Pending;
            };
            if (_isCkToken(to) and input.size() > 4){
                switch(ABI.decodeErc20Transfer(input), ABI.decodeErc20TransferFrom(input)){
                    case(?(tx), _){
                        token := to;
                        to := tx.to;
                        value := tx.value;
                    };
                    case(_, ?(tx)){
                        token := to;
                        from := tx.from;
                        to := tx.to;
                        value := tx.value;
                    };
                    case(_, _){};
                };
            };
            return (true, ?{token=token; from=from; to=to; value=value}, blockNumber, confirmation, nonce, ?jsons);
        }catch(e){
            return (false, null, 0, #Unknown, null, null);
        };
    };
    private func _fetchTxReceipt(_txHash: TxHash): async* (success: Bool, height: BlockHeight, confirmation: Status, returns: ?[Text]){
        let minRpcRequests : Nat = minRpcConfirmations;
        try{
            let params = "[\""# _txHash #"\"]";
            let (res, jsons) = await* _fetchValues("eth_getTransactionReceipt", params, 4000, minRpcRequests, 
            [(#Value, "result/status"), (#Value, "result/blockNumber")]);
            var status : Nat = switch(res[0]){ case(#Nat(v)){ v }; case(_){ 0 } };
            var blockNumber : Nat = switch(res[1]){ case(#Nat(v)){ v }; case(_){ 0 } };
            // var returns : ?Text = switch(res[2]){ case(#Text(v)){ ?v }; case(_){ null } };
            var confirmation: Status = #Unknown;

            if (_getBlockNumber() >= blockNumber + minConfirmations){
                confirmation := #Confirmed;
            }else if (blockNumber > 0){
                confirmation := #Pending;
            };
            if (status == 1){
                return (true, blockNumber, confirmation, ?jsons);
            }else{
                return (false, blockNumber, #Failure, ?jsons);
            };
        }catch(e){
            return (false, 0, #Unknown, null);
        };
    };
    private func _fetchERC20Metadata(_tokenId: EthAddress): async* {symbol: Text; decimals: Nat8 }{
        let minRpcRequests : Nat = minRpcConfirmations;
        let blockNumber: Text = "latest";
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = await* _getEthAddress(mainAccoundId, false);

        let args1 = ABI.toHex(ABI.encodeErc20Symbol());
        let params1 = "[{"# 
            "\"from\": \""# mainAddress #"\"," # 
            "\"to\": \""# _tokenId #"\"," #
            "\"data\": \""# args1 #"\"" # 
        "}, \""# blockNumber #"\"]";
        let symbol: Text = ABI.decodeErc20Symbol(ETHCrypto.trimQuote(await* _fetchString("eth_call", params1, 1000, minRpcRequests, "result")));

        let args2 = ABI.toHex(ABI.encodeErc20Decimals());
        let params2 = "[{"# 
            "\"from\": \""# mainAddress #"\"," # 
            "\"to\": \""# _tokenId #"\"," #
            "\"data\": \""# args2 #"\"" # 
        "}, \""# blockNumber #"\"]";
        let decimals: Nat = await* _fetchNumber("eth_call", params2, 1000, minRpcRequests, "result");

        return {symbol = symbol; decimals = Nat8.fromNat(decimals) };
    };
    
    private func _sendCkToken(tokenId: EthAddress, fromSubaccount: Blob, to: Account, amount: Wei) : SagaTM.Toid{
        // send ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let toAccountId = _accountId(to.owner, to.subaccount);
        let toIcrc1Account : ICRC1.Account = {owner=to.owner; subaccount=_toSaBlob(to.subaccount) };
        let saga = _getSaga();
        let toid : Nat = saga.create("send", #Forward, ?toAccountId, null);
        let args : ICRC1.TransferArgs = {
            from_subaccount = ?fromSubaccount;
            to = toIcrc1Account;
            amount = amount;
            fee = null;
            memo = null;
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        saga.close(toid);
        ignore _putEvent(#send({toid = ?toid; to = to; icTokenCanisterId = ckTokenCanisterId; amount = amount}), ?toAccountId);
        return toid;
    };
    private func _sendCkToken2(tokenId: EthAddress, fromSubaccount: Blob, icrc1To: ICRC1.Account, amount: Wei) : async* { #Ok: Nat; #Err: ICRC1.TransferError; }{
        // send ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let icrc1: ICRC1.Self = actor(Principal.toText(ckTokenCanisterId));
        let args : ICRC1.TransferArgs = {
            memo = null;
            amount = amount;
            fee = null;
            from_subaccount = ?fromSubaccount;
            to = icrc1To;
            created_at_time = null;
        };
        return await icrc1.icrc1_transfer(args);
    };
    private func _mintCkToken(tokenId: EthAddress, account: Account, amount: Wei, txi: ?TxIndex, ictcName: ?Text) : SagaTM.Toid{
        // mint ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(Option.get(txi, 0)))); 
        let accountId = _accountId(account.owner, account.subaccount);
        let icrc1Account : ICRC1.Account = { owner = account.owner; subaccount = _toSaBlob(account.subaccount); };
        let (userAddress, userNonce) = _getEthAddressQuery(accountId);
        let saga = _getSaga();
        let toid : Nat = saga.create(Option.get(ictcName, "mint_ck_token"), #Forward, ?txiBlob, null);
        let args : ICRC1.TransferArgs = {
            from_subaccount = null;
            to = icrc1Account;
            amount = amount;
            fee = null;
            memo = switch(ABI.fromHex(userAddress)){ case(?memo){ ?Blob.fromArray(memo) }; case(_){ null }; };
            created_at_time = null; // nanos
        };
        let task = _buildTask(?txiBlob, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        saga.close(toid);
        ignore _putEvent(#mint({toid = toid; account = account; icTokenCanisterId = ckTokenCanisterId; amount = amount}), ?accountId);
        return toid;
    };
    private func _burnCkToken(tokenId: EthAddress, fromSubaccount: Blob, amount: Wei, account: Account, ictcName: ?Text) : SagaTM.Toid{
        // burn ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let accountId = _accountId(account.owner, account.subaccount);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let saga = _getSaga();
        let toid : Nat = saga.create(Option.get(ictcName, "burn_ck_token"), #Forward, ?accountId, null);
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?fromSubaccount;
            to = mainIcrc1Account;
            amount = amount;
            fee = null;
            memo = null;
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(burnArgs)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        saga.close(toid);
        ignore _putEvent(#burn({toid = ?toid; account = account; address = ""; icTokenCanisterId = ckTokenCanisterId; tokenBlockIndex = 0; amount = amount}), ?accountId);
        return toid;
    };
    private func _burnCkToken2(_tokenId: EthAddress, _fromSubaccount: Blob, _address: EthAddress, _amount: Wei, _account: Account) : async* { #Ok: Nat; #Err: ICRC1.TransferError; }{
        await* _ictcSagaRun(0, false);
        let accountId = _accountId(_account.owner, _account.subaccount);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let toAddress = _toLower(_address);
        let ckLedger = _getCkLedger(_tokenId);
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?_fromSubaccount;
            to = mainIcrc1Account;
            amount = _amount;
            fee = null;
            memo = switch(ABI.fromHex(toAddress)){ case(?memo){ ?Blob.fromArray(memo) }; case(_){ null }; };
            created_at_time = null; // nanos
        };
        let res = await ckLedger.icrc1_transfer(burnArgs);
        switch(res){
            case(#Ok(height)){
                let saga = _getSaga();
                let toid : Nat = saga.create("burn_ck_token(notify)", #Forward, ?accountId, null);
                let task0 = _buildTask(null, Principal.fromActor(this), #custom(#burnNotify(_tokenId, _amount, height)), [], 0, null, null);
                let _ttid0 = saga.push(toid, task0, null, null);
                saga.close(toid);
                ignore _putEvent(#burn({toid = null; account = _account; address = toAddress; icTokenCanisterId = _getCkTokenInfo(_tokenId).ckLedgerId; tokenBlockIndex = height; amount = _amount}), ?accountId);
            };
            case(_){};
        };
        return res;
    };
    private func _sendFromFeeBalance(_account: Account, _value: Wei): async* (){
        // icETH 
        let token = _getCkTokenInfo(eth_);
        let icrc1: ICRC1.Self = actor(Principal.toText(token.ckLedgerId));
        let ckFee = await icrc1.icrc1_fee();
        if (_value >= ckFee*2){
            let mainFeeBalance = _getFeeBalance(eth_);
            ignore _subFeeBalance(eth_, Nat.min(mainFeeBalance, _value));
            let toid = _sendCkToken(eth_, Blob.fromArray(sa_one), _account, Nat.sub(_value, ckFee));
            await* _ictcSagaRun(toid, false);
        };
    };
    private func _txCallback(_txIndex: TxIndex) : [SagaTM.Toid]{
        var toids: [SagaTM.Toid] = [];
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                if (tx.status == #Confirmed){
                    if (tx.txType == #Deposit){ // _isPending()
                        let isERC20 = tx.tokenId != eth_;
                        let gasFee = tx.fee; //_getEthGas(tx.tokenId); // eth Wei // Getting the fee from the tx record
                        let ckFee = _getCkFeeForDepositing2(tx.tokenId, tx.fee); // {eth; token} Wei // Getting the fee from the tx record
                        var amount: Wei = tx.amount;
                        // Mint fee
                        var fee: Wei = 0;
                        if (isERC20){
                            fee := ckFee.token;
                            amount -= Nat.min(amount, fee);
                            ignore _addFeeBalance(tx.tokenId, fee);
                            let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                            let toid = _mintCkToken(tx.tokenId, feeAccount, fee, ?_txIndex, ?"mint_ck_token(fee)");
                            toids := Tools.arrayAppend(toids, [toid]);
                        }else{
                            fee := Nat.sub(ckFee.eth, gasFee.maxFee);
                            amount -= Nat.min(amount, fee);
                            ignore _addFeeBalance(tx.tokenId, fee);
                            let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                            let toid = _mintCkToken(tx.tokenId, feeAccount, fee, ?_txIndex, ?"mint_ck_token(fee)");
                            toids := Tools.arrayAppend(toids, [toid]);
                        };
                        ignore _addBalance(tx.account, tx.tokenId, amount);
                        ignore _removeDepositingTxIndex(accountId, _txIndex);
                        ignore _putEvent(#depositResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=amount; fee = ?fee})), ?accountId);
                        _stats(tx.tokenId, #Minting, amount);
                        // Mint
                        let depositingBalance = Nat.min(amount, _getBalance(tx.account, tx.tokenId));
                        if (depositingBalance > 0){
                            ignore _subBalance(tx.account, tx.tokenId, depositingBalance);
                            ignore _addBalance({owner = Principal.fromActor(this); subaccount = null}, tx.tokenId, depositingBalance);
                            // mint ckToken
                            let toid = _mintCkToken(tx.tokenId, tx.account, depositingBalance, ?_txIndex, null);
                            toids := Tools.arrayAppend(toids, [toid]);
                        };
                    }else if(tx.txType == #DepositGas){ // _isPending()
                        ignore _putEvent(#depositGasResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=tx.amount})), ?accountId);
                    }else if(tx.txType == #Withdraw){ // _isPending()
                        _removeRetrievingTxIndex(_txIndex);
                        ignore _putEvent(#withdrawResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=tx.amount})), ?accountId);
                        _stats(tx.tokenId, #Retrieval, tx.amount);
                    };
                }else if (tx.status == #Failure){
                    if (tx.txType == #Deposit){
                        ignore _removeDepositingTxIndex(_accountId(tx.account.owner, tx.account.subaccount), _txIndex);
                        ignore _putEvent(#depositResult(#err({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=0})), ?accountId);
                    }else if(tx.txType == #DepositGas){
                        ignore _putEvent(#depositGasResult(#err({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=0})), ?accountId);
                    }else if(tx.txType == #Withdraw){
                        _removeRetrievingTxIndex(_txIndex);
                        ignore _putEvent(#withdrawResult(#err({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=0})), ?accountId);
                    };
                };
            };
            case(_){};
        };
        return toids;
    };
    // The function is idempotent, allowing it to be called repeatedly.
    private func _txCompletedAndCallback(_txIndex: TxIndex) : async* (completed: Bool, confirming: Bool, status: Minter.Status){
        var completed: Bool = false;
        var confirming: Bool = false;
        var status: Minter.Status = #Pending;
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Sending or tx.status == #Submitted or tx.status == #Pending){
                    let txHashs = tx.txHash;
                    status := tx.status;
                    var minConfirms = minConfirmations;
                    if (tx.txType == #DepositGas){
                        minConfirms := 1;
                    };
                    var countFailure : Nat = 0;
                    var receiptTemp: ?Text = null;
                    label TxReceipt for (txHash in txHashs.vals()){
                        let (succeeded, blockHeight, txStatus, jsons) = await* _fetchTxReceipt(txHash);
                        var res : ?Text = null;
                        switch(jsons){
                            case(?strArray){
                                if (strArray.size() > 0){ res := ?strArray[0] };
                            };
                            case(_){};
                        };
                        if (succeeded and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirms){
                            completed := true;
                            status := #Confirmed;
                            receiptTemp := res;
                            break TxReceipt;
                        }else if (succeeded and (blockHeight == 0 or _getBlockNumber() < blockHeight + minConfirms)){
                            status := #Pending;
                            receiptTemp := res;
                            if (blockHeight > 0 and _getBlockNumber() < blockHeight + minConfirms){
                                confirming := true;
                            };
                        }else if (not(succeeded) and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirms){
                            countFailure += 1;
                        }else{ // not(succeeded) and blockHeight < blockHeight + minConfirms
                            // unknowen
                        };
                    };
                    if (countFailure == txHashs.size() and _isPending(_txIndex)){ // _isPending()
                        completed := true;
                        status := #Failure;
                    };
                    if (status != tx.status and _isPending(_txIndex)){// _isPending()
                        _updateTx(_txIndex, {
                            fee = null;
                            amount = null;
                            nonce = null;
                            toids = null;
                            txHash = null;
                            tx = null;
                            rawTx = null;
                            signedTx = null;
                            receipt = receiptTemp;
                            rpcRequestId = null;
                            kytRequestId = null;
                            status = ?status;
                            ts = null;
                        }, null);
                        // Callback
                        let _toids = _txCallback(_txIndex);
                        // if (toids.size() > 0){
                        //     await* _ictcSagaRun(0, false);
                        // };
                    };
                };
            };
            case(_){};
        };
        return (completed, confirming, status);
    };
    // Called proactively to update the txn status, or when it has been unconfirmed for too long.
    private func _syncTxStatus(_txIndex: TxIndex, _immediately: Bool) : async* (){
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                if ((tx.status == #Submitted or tx.status == #Pending) and (_immediately or (_now() > ts + ckNetworkBlockSlot * minConfirmations * 3 / 2) )){
                    if (_now() > ts + ckNetworkBlockSlot * minConfirmations * 3 / 2){
                        _updateTx(_txIndex, {
                            fee = null;
                            amount = null;
                            nonce = null;
                            toids = null;
                            txHash = null;
                            tx = null;
                            rawTx = null;
                            signedTx = null;
                            receipt = null;
                            rpcRequestId = null;
                            kytRequestId = null;
                            status = null;
                            ts = ?_now();
                        }, null);
                    };
                    if (tx.txType == #Deposit and tx.tokenId != eth_ and _txIndex > 0){
                        ignore await* _txCompletedAndCallback(Nat.sub(_txIndex, 1)); // #DepositGas
                    };
                    ignore await* _txCompletedAndCallback(_txIndex);
                    await* _ictcSagaRun(0, false);
                };
            };
            case(_){};
        };
    };
    private func _syncTxs() : async* (){
        for ((txi, (tx, ts, cts)) in Trie.iter(transactions)){
            if (_now() > ts + ckNetworkBlockSlot * minConfirmations * 2){
                await* _syncTxStatus(txi, false);
            };
        };
    };
    private func _ictcDepositTx(_account : Account, _tokenId: Text, _amount: Nat, _networkFee: EthGas, _gasFee: EthGas) : (TxIndex, SagaTM.Toid){
        var preTids: [Nat] = [];
        let saga = _getSaga();
        let tokenId = _tokenId;
        let amount = _amount;
        let networkFee = _networkFee; // for ETH
        let gasFee = _gasFee; // for ETH or ERC20
        let depositFee = gasFee.maxFee;
        let accountId = _accountId(_account.owner, _account.subaccount);
        let (userAddress, userNonce) = _getEthAddressQuery(accountId);
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
        let isERC20 = tokenId != eth_;
        var txi0 = 0; // depositing gas txn
        if (isERC20){
            txi0 := _newTx(#DepositGas, _account, eth_, mainAddress, userAddress, gasFee.maxFee, networkFee);
        };
        let txi = _newTx(#Deposit, _account, tokenId, userAddress, mainAddress, amount, gasFee);
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
        _putDepositingTxIndex(accountId, txi);
        _putAddressAccount(tokenId, userAddress, _account);
        if (isERC20){
            let txi0Blob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi0))); 
            let toid0 : Nat = saga.create("deposit_gas", #Forward, ?txi0Blob, null);
            let task0_1 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#getNonce(txi0, ?[toid0])), [], 0, null, null);
            let _ttid0_1 = saga.push(toid0, task0_1, null, null);
            let task0_2 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#createTx(txi0)), [], 0, null, null);
            let _ttid0_2 = saga.push(toid0, task0_2, null, null);
            let task0_3 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#signTx(txi0)), [], 0, null, null);
            let _ttid0_3 = saga.push(toid0, task0_3, null, null);
            let task0_4 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#sendTx(txi0)), [], 0, null, null);
            let _ttid0_4 = saga.push(toid0, task0_4, null, null);
            let task0_5 = _buildTask(?txi0Blob, Principal.fromActor(this), #custom(#syncTx(txi0, true)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
            let ttid0_5 = saga.push(toid0, task0_5, null, null);
            preTids := [ttid0_5];
            saga.close(toid0);
            _updateTxToids(txi0, [toid0]);
            ignore _putEvent(#depositGas({txIndex = txi0; toid = toid0; account = _account; address = userAddress; amount = gasFee.maxFee}), ?accountId);
        };
        let toid : Nat = saga.create("deposit_method1(evm->ic)", #Forward, ?txiBlob, null);
        let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#getNonce(txi, ?[toid])), preTids, 0, null, null);
        let _ttid1 = saga.push(toid, task1, null, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(txi)), [], 0, null, null);
        let _ttid2 = saga.push(toid, task2, null, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(txi)), [], 0, null, null);
        let _ttid3 = saga.push(toid, task3, null, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(txi)), [], 0, null, null);
        let _ttid4 = saga.push(toid, task4, null, null);
        let task5 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(txi, false)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let _ttid5 = saga.push(toid, task5, null, null);
        saga.close(toid);
        _updateTxToids(txi, [toid]);
        ignore _putEvent(#deposit({txIndex = txi; toid = toid; account = _account; address = userAddress; token = tokenId; amount = amount; fee = ?depositFee}), ?accountId);
        return (txi, toid);
    };
    private func _depositNotify(_token: ?EthAddress, _account : Account) : async* {
        #Ok : Minter.UpdateBalanceResult; 
        #Err : Minter.ResultError;
    }{
        let accountId = _accountId(_account.owner, _account.subaccount);
        let (userAddress, userNonce) = _getEthAddressQuery(accountId);
        if (Text.size(userAddress) != 42){
            return #Err(#GenericError({code = 402; message="402: Address is not available."}));
        };
        let tokenId = _toLower(Option.get(_token, eth_));
        let isERC20 = tokenId != eth_;
        if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let _gasPrice = await* _fetchGasPrice();
        };
        let networkFee = _getEthGas(eth_); // for ETH
        let gasFee = _getEthGas(tokenId); // for ETH or ERC20
        let ckFee = _getCkFeeForDepositing(tokenId); // {eth; token} Wei 
        var depositAmount: Wei = 0;
        var depositFee: Wei = 0;
        if (Option.isSome(_getDepositingTxIndex(accountId))){
            let txi = Option.get(_getDepositingTxIndex(accountId),0);
            await* _syncTxStatus(txi, false); // Deposit
            return #Err(#GenericError({code = 402; message="402: You have a deposit waiting for network confirmation."}));
        }else{ // New deposit
            // Notice: If the third parameter of _fetchBalance() is true, it means that the balance is queried from the latest block, 
            // so the balance may be inaccurate, which may lead to ‘Insufficient Balance’ error in the following ICTC tasks. 
            // In this case, set the ICTC transaction to Done to cancel the operation, and do not blindly resend it.
            depositAmount := await* _fetchBalance(tokenId, userAddress, true); // Wei  
            if (depositAmount > ckFee.token and depositAmount > _getTokenMinAmount(tokenId) and Option.isNull(_getDepositingTxIndex(accountId))){ 
                var amount = depositAmount;
                if (isERC20){
                    if (_getFeeBalance(eth_) >= networkFee.maxFee + gasFee.maxFee){
                        ignore _subFeeBalance(eth_, networkFee.maxFee + gasFee.maxFee);
                        let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                        ignore _burnCkToken(eth_, Blob.fromArray(sa_one), networkFee.maxFee + gasFee.maxFee, feeAccount, ?"burn_ck_token(fee)");
                    }else{
                        return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
                    };
                }else{
                    depositFee := gasFee.maxFee;
                    amount -= Nat.min(amount, depositFee);
                };
                //ICTC: 
                let (txi, toid) = _ictcDepositTx(_account, tokenId, amount, networkFee, gasFee);
                // await* _ictcSagaRun(toid, false);
                let _f = _getSaga().run(toid);
                return #Ok({ 
                    blockIndex = Nat.sub(blockIndex, 1); 
                    amount = amount;
                    txIndex = txi;
                    toid = toid;
                });
            }else {
                return #Err(#GenericError({code = 402; message="402: No new deposit, or the transaction is pending, or the amount is less than the minimum value."}));
            };
        };
    };
    
    private func _updateBalance(_aid: ?AccountId): async* (){ 
        switch(_aid){
            case(?aid){
                assert(aid != _accountId(Principal.fromActor(this), null));
                switch(Trie.get(balances, keyb(aid), Blob.equal)){
                    case(?tokenBalances){
                        for((tokenIdBlob, (account, x)) in Trie.iter(tokenBalances)){
                            let tokenId = ABI.toHex(Blob.toArray(tokenIdBlob));
                            let depositingBalance = _getBalance(account, tokenId);
                            if (depositingBalance > 0){
                                ignore _subBalance(account, tokenId, depositingBalance);
                                ignore _addBalance({owner = Principal.fromActor(this); subaccount = null}, tokenId, depositingBalance);
                                // mint ckToken
                                let toid = _mintCkToken(tokenId, account, depositingBalance, null, ?"mint_ck_token(update)");
                                await* _ictcSagaRun(toid, false);
                            };
                        };
                    };
                    case(_){};
                };
            };
            case(_){
                for ((accountId, tokenBalances) in Trie.iter(balances)){
                    if (accountId != _accountId(Principal.fromActor(this), null)){ // Non-pool account
                        for((tokenIdBlob, (account, x)) in Trie.iter(tokenBalances)){
                            let tokenId = ABI.toHex(Blob.toArray(tokenIdBlob));
                            let depositingBalance = _getBalance(account, tokenId);
                            if (depositingBalance > 0){
                                ignore _subBalance(account, tokenId, depositingBalance);
                                ignore _addBalance({owner = Principal.fromActor(this); subaccount = null}, tokenId, depositingBalance);
                                // mint ckToken
                                let toid = _mintCkToken(tokenId, account, depositingBalance, null, ?"mint_ck_token(update)");
                                await* _ictcSagaRun(toid, false);
                            };
                        };
                    };
                };
            };
        };
    };
    private func _coverPendingTxs(): async* (){
        for ((accountId, txi) in Trie.iter(deposits)){
            switch(Trie.get(transactions, keyn(txi), Nat.equal)){
                case(?(tx, ts, cts)){
                    let coveredTs = Option.get(cts, ts);
                    if (_now() > coveredTs + 30*60 and Array.size(tx.txHash) < 5){
                        try{
                            await* _syncTxStatus(txi, true);
                            ignore await* _coverTx(txi, false, ?true, 0, true, true);
                        }catch(e){};
                    };
                };
                case(_){};
            };
        };
    };

    private func _method2TxnSuccessCallback(_account: Account, _txHash: TxHash, _tokenTxn: Minter.TokenTxn, _signature: [Nat8]) : [SagaTM.Toid]{
        let tokenTxn = _tokenTxn;
        let accountId = _accountId(_account.owner, _account.subaccount);
        let ckFee = _getFixedFee(tokenTxn.token); // {eth; token} Wei 
        var toids: [SagaTM.Toid] = [];
        var amount: Wei = tokenTxn.value;
        var fee: Wei = ckFee.token;
        if (amount > fee){
            amount -= fee;
            ignore _addFeeBalance(tokenTxn.token, fee);
            let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
            let toid = _mintCkToken(tokenTxn.token, feeAccount, fee, null, ?"mint_ck_token(fee)");
            toids := Tools.arrayAppend(toids, [toid]);
            ignore _addBalance(_account, tokenTxn.token, amount);
            _confirmDepositTxn(_txHash, #Confirmed, ?(tokenTxn), ?_now(), null);
            _removePendingDepositTxn(_txHash);
            _putAddressAccount(tokenTxn.token, tokenTxn.from, _account);
            _putTxAccount(tokenTxn.token, _txHash, tokenTxn.from, _account);
            ignore _putEvent(#claimDepositResult(#ok({token = tokenTxn.token; account = _account; from = tokenTxn.from; amount = amount; fee = ?fee; txHash = _txHash; signature = ABI.toHex(_signature)})), ?accountId);
            _stats(tokenTxn.token, #Minting, amount);
            let depositingBalance = Nat.min(amount, _getBalance(_account, tokenTxn.token));
            if (depositingBalance > 0){
                ignore _subBalance(_account, tokenTxn.token, depositingBalance);
                ignore _addBalance({owner = Principal.fromActor(this); subaccount = null}, tokenTxn.token, depositingBalance);
                // mint ckToken
                let toid = _mintCkToken(tokenTxn.token, _account, depositingBalance, null, null);
                toids := Tools.arrayAppend(toids, [toid]);
            };
        };
        return toids;
    };
    private func _method2TxnFailedCallback(_account: Account, _txHash: TxHash, _signature: [Nat8], _message: Text) : 
    (status: Status, message: ?Text, token: ?Text, amount: ?Nat){
        let accountId = _accountId(_account.owner, _account.subaccount);
        _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?_message);
        _removePendingDepositTxn(_txHash);
        _putFailedTxnLog(_txHash);
        ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = _message})), ?accountId);
        return (#Failure, ?_message, null, null);
    };
    private func _syncMethod2TxnStatus(_txHash: TxHash) : async* (status: Status, message: ?Text, token: ?Text, amount: ?Nat){
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccoundId);
        let txhBlob = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(depositTxns, keyb(txhBlob), Blob.equal)){
            case(?(item, ts)){ 
                if (item.status == #Failure){
                    return (#Failure, item.error, null, null);
                }else if (item.status == #Confirmed){
                    return (#Confirmed, null, null, null);
                }else{ // #Pending
                    switch(Trie.get(pendingDepositTxns, keyb(txhBlob), Blob.equal)){
                        case(?(txHash, account, signature, isVerified, ts, optToid)){
                            let accountId = _accountId(account.owner, account.subaccount);
                            let (succeeded, txn, blockHeight, status, nonce, jsons) = await* _fetchTxn(_txHash);
                            switch(succeeded, txn, status){
                                case(true, ?(tokenTxn), #Confirmed){
                                    if (not(_isCkToken(tokenTxn.token)) and _isPendingTxn(txHash)){
                                        let message = "Not a supported token.";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    };
                                    if (_getBlockNumber() >= blockHeight + VALID_BLOCKS_FOR_CLAIMING_TXN and _isPendingTxn(txHash)){
                                        let message = "It has expired (valid for "# Nat.toText(VALID_BLOCKS_FOR_CLAIMING_TXN) #" blocks).";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    };
                                    if (mainAddress != tokenTxn.to and _isPendingTxn(txHash)){
                                        let message = "The recipient is not the ck address of this Canister.";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    };
                                    if (tokenTxn.value == 0 and _isPendingTxn(txHash)){
                                        let message = "The value of the transaction cannot be zero.";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    };
                                    // validate
                                    let message: [Nat8] = _depositingMsg(txHash, account);
                                    let msgHash = ETHCrypto.sha3(message);
                                    var address = ""; 
                                    switch(ETHCrypto.recover(signature, msgHash, tokenTxn.from, ck_chainId, ecContext)){
                                        case(#ok(addr)){ address := addr };
                                        case(#err(e)){ throw Error.reject(e); };
                                    };
                                    if (address == tokenTxn.from and mainAddress == tokenTxn.to and _isPendingTxn(txHash)){ 
                                        _validatePendingDepositTxn(txHash); // validated
                                        _putDepositTxn(account, txHash, signature, #Pending, null, null);
                                        let (txSucceeded, txBlockHeight, txStatus, txJsons) = await* _fetchTxReceipt(txHash);
                                        if (txSucceeded and txBlockHeight > 0 and _getBlockNumber() >= txBlockHeight + minConfirmations and _isPendingTxn(txHash)){
                                            // let isERC20 = tokenTxn.token != eth_;
                                            //let gasFee = _getEthGas(tokenTxn.token); // {.... maxFee }eth Wei
                                            let ckFee = _getFixedFee(tokenTxn.token); // {eth; token} Wei 
                                            var amount: Wei = tokenTxn.value;
                                            var fee: Wei = ckFee.token;
                                            if (amount > fee){
                                                let _toids = _method2TxnSuccessCallback(account, txHash, tokenTxn, signature);
                                                // if (toids.size() > 0){
                                                //     await* _ictcSagaRun(0, false);
                                                // };
                                                return (#Confirmed, ?"txn is confirmed.", ?tokenTxn.token, ?amount);
                                            }else{
                                                let message = "The amount is too low.";
                                                return _method2TxnFailedCallback(account, txHash, signature, message);
                                            };
                                        }else if (txSucceeded and (txBlockHeight == 0 or _getBlockNumber() < txBlockHeight + minConfirmations) and _isPendingTxn(txHash)){
                                            return (#Pending, ?"The transaction is pending.", null, null);
                                        }else if (not(txSucceeded) and txBlockHeight > 0 and _getBlockNumber() >= txBlockHeight + minConfirmations and _isPendingTxn(txHash)){
                                            let message = "Failed transaction.";
                                            return _method2TxnFailedCallback(account, txHash, signature, message);
                                        }else if (not(txSucceeded) and _isPendingTxn(txHash)){
                                            let message = "An error occurred while fetching the transaction.";
                                            return _method2TxnFailedCallback(account, txHash, signature, message);
                                        }else{
                                            return (#Unknown, null, null, null);
                                        };
                                    }else if (_isPendingTxn(txHash)){
                                        let message = "Signature validation failed.";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    }else{
                                        return (#Unknown, null, null, null);
                                    };
                                };
                                case(true, ?(tokenTxn), #Pending){
                                    if (_isPendingTxn(txHash)){
                                        _putDepositTxn(account, txHash, signature, #Pending, null, ?"The transaction is pending.");
                                    };
                                    return (#Pending, ?"The transaction is pending.", null, null);
                                };
                                case(false, _, _){
                                    if (_now() > ts + 20*60 and _isPendingTxn(txHash)){
                                        let message = "Error: The transaction was not found within 20 minutes. Please wait for the transaction confirmation and submit again.";
                                        return _method2TxnFailedCallback(account, txHash, signature, message);
                                    }else{
                                        return (#Unknown, ?"Unknown reason.", null, null);
                                    }; 
                                };
                                case(_, _, _){
                                    return (#Unknown, ?"Unknown error.", null, null);
                                };
                            };
                        };
                        case(_){
                            throw Error.reject("404: There is no pending txn.");
                        };
                    };
                };
            };
            case(_){
                throw Error.reject("404: txn does not exist.");
            };
        };
    };
    private func _method2TxnNotify(_account: Account, _txHash: TxHash) : async* (){
        let accountId = _accountId(_account.owner, _account.subaccount);
        let txHashBlob = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        let saga = _getSaga();
        let toid : Nat = saga.create("deposit_method2(evm->ic)", #Backward, ?txHashBlob, null);
        let task_1 = _buildTask(?accountId, Principal.fromActor(this), #custom(#validateTx(_txHash)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let comp_1 = _buildTask(null, Principal.fromActor(this), #__skip, [], 0, null, null);
        let _ttid_1 = saga.push(toid, task_1, ?comp_1, null);
        saga.close(toid);
        _putToidToPendingDepositTxn(_txHash, ?toid);
        // await* _ictcSagaRun(toid, false);
        let _f = _getSaga().run(toid);
    };
    
    private func _depositingMsg(_txHash: TxHash, _account: Account) : [Nat8]{
        let salt = Blob.toArray(Principal.toBlob(Principal.fromActor(this)));
        let domainType = "EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)";
        let domainValues = [
            #string("icRouter: Cross-chain Asset Router"),
            #string("1"),
            #uint256(ck_chainId),
            #bytes32(ABI.toHex(ABI.toBytes32(salt)))
        ];
        let messageType = "ICRouter(string operation,bytes32 txHash,string principal,bytes32 subaccount)";
        let messageValues = [
            #string("deposit for minting token on IC network"),
            #bytes32(_txHash),
            #string(Principal.toText(_account.owner)),
            #bytes32(ABI.toHex(Option.get(_account.subaccount, sa_zero)))
        ];
        return EIP712.hashMessage(domainType, domainValues, messageType, messageValues).0;
    };

    private func _ictcSendNativeToken(_account: Account, _tokenId: EthAddress, _amount: Nat, _gasFee: EthGas, _ckFee: CkFee, _to: EthAddress, _burntBlockHeight: Nat) : (txi: TxIndex, toid: SagaTM.Toid){
        let tokenId = _tokenId;
        let account = _account;
        let accountId = _accountId(account.owner, account.subaccount);
        let toAddress = _to;
        let height = _burntBlockHeight;
        let retrieveAccount : Minter.Account = { owner = Principal.fromActor(this); subaccount = ?Blob.toArray(accountId); };
        let mainAccount: Account = {owner = Principal.fromActor(this); subaccount = null };
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccoundId);
        let gasFee = _gasFee; // for ETH or ERC20
        let ckFee = _ckFee; // {eth; token} Wei 
        var sendingAmount = _amount;
        var sendingFee: Wei = 0;
        if (sendingAmount > ckFee.token and sendingAmount >= _getTokenMinAmount(tokenId)){
            sendingFee := ckFee.token;
            sendingAmount -= ckFee.token;
        };
        ignore _subBalance(mainAccount, tokenId, Nat.min(_getBalance(mainAccount, tokenId), _amount)); 
        ignore _addFeeBalance(tokenId, ckFee.token);
        let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
        ignore _mintCkToken(tokenId, feeAccount, ckFee.token, null, ?"mint_ck_token(fee)");
        ignore _subFeeBalance(eth_, Nat.min(_getFeeBalance(eth_), gasFee.maxFee));
        ignore _burnCkToken(eth_, Blob.fromArray(sa_one), gasFee.maxFee, feeAccount, ?"burn_ck_token(fee)");
        let txi = _newTx(#Withdraw, account, tokenId, mainAddress, toAddress, sendingAmount, gasFee);
        let status : Minter.RetrieveStatus = {
            account = account;
            retrieveAccount = retrieveAccount; // ck token about to be burned
            burnedBlockIndex = height;
            ethAddress = toAddress;
            amount = sendingAmount; 
            txIndex = txi;
        };
        retrievals := Trie.put(retrievals, keyn(txi), Nat.equal, status).0;
        _putWithdrawal(accountId, txi);
        _putRetrievingTxIndex(txi);
        _putAddressAccount(tokenId, toAddress, account);
        // ICTC
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
        let saga = _getSaga();
        let toid : Nat = saga.create("retrieve(ic->evm)", #Forward, ?txiBlob, null);
        let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#getNonce(txi, ?[toid])), [], 0, null, null);
        let _ttid1 = saga.push(toid, task1, null, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(txi)), [], 0, null, null);
        let _ttid2 = saga.push(toid, task2, null, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(txi)), [], 0, null, null);
        let _ttid3 = saga.push(toid, task3, null, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(txi)), [], 0, null, null);
        let _ttid4 = saga.push(toid, task4, null, null);
        let task5 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(txi, false)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let _ttid5 = saga.push(toid, task5, null, null);
        saga.close(toid);
        _updateTxToids(txi, [toid]);
        return (txi, toid);
    };
    
    private func _clearMethod2Txn() : async* (){
        for ((k, (txHash, account, signature, isVerified, ts, optToid)) in Trie.iter(pendingDepositTxns)){
            if (_now() > ts + 2*20*60){
                ignore _method2TxnFailedCallback(account, txHash, signature, "");
                switch(optToid){
                    case(?toid){ ignore _getSaga().done(toid, #Recovered, true); };
                    case(_){};
                };
            }
        };
    };
    private func _putEvent(_event: Event, _a: ?AccountId) : BlockHeight{
        blockEvents := ICEvents.putEvent<Event>(blockEvents, blockIndex, _event);
        switch(_a){
            case(?(accountId)){ 
                accountEvents := ICEvents.putAccountEvent(accountEvents, firstBlockIndex, accountId, blockIndex);
            };
            case(_){};
        };
        blockIndex += 1;
        return Nat.sub(blockIndex, 1);
    };
    private func _getLatestVisitTime(_owner: Principal) : Timestamp{
        switch(Trie.get(latestVisitTime, keyp(_owner), Principal.equal)){
            case(?(v)){ return v };
            case(_){ return 0 };
        };
    };
    private func _setLatestVisitTime(_owner: Principal) : (){
        latestVisitTime := Trie.put(latestVisitTime, keyp(_owner), Principal.equal, _now()).0;
        latestVisitTime := Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 3600 // 1 hour
        });
    };
    private func _dosCheck(_accountId: AccountId, _max: Nat) : Bool{
        let data = Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 30 // 30 seconds
        });
        if (Trie.size(data) >= _max){
            if(Option.isSome(Trie.get(deposits, keyb(_accountId), Blob.equal))){
                return true;
            }else if(Option.isSome(Trie.get(balances, keyb(_accountId), Blob.equal))){
                return true;
            }else if(Option.isSome(Trie.get(withdrawals, keyb(_accountId), Blob.equal))){
                return true;
            }else{
                return false;
            };
        }else{
            return true;
        };
    };

    private func _clearRpcLogs(_idFrom: RpcId, _idTo: RpcId) : (){
        for (i in Iter.range(_idFrom, _idTo)){
            ck_rpcLogs := Trie.remove(ck_rpcLogs, keyn(i), Nat.equal).0;
        };
        firstRpcId := _idTo + 1;
    };
    private func _clearRpcRequests(_idFrom: RpcRequestId, _idTo: RpcRequestId) : (){
        for (i in Iter.range(_idFrom, _idTo)){
            ck_rpcRequests := Trie.remove(ck_rpcRequests, keyn(i), Nat.equal).0;
        };
        firstRpcRequestId := _idTo + 1;
    };

    /** Public functions **/
    /// Deposit Method : 1
    public shared(msg) func get_deposit_address(_account : Account): async EthAddress{
        assert(_notPaused() or _onlyOwner(msg.caller));
        assert(depositMethod == 1 or depositMethod == 3);
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        let accountId = _accountId(_account.owner, _account.subaccount);
        if (not(_dosCheck(accountId, 15)) or not(_dosCheck(_accountId(msg.caller, null), 15))){
            throw Error.reject("400: The network is busy, please try again later!");
        };
        if (Option.isSome(_getDepositingTxIndex(accountId))){
            throw Error.reject("405: You have a deposit waiting for network confirmation.");
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("403: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        let account = await* _getEthAddress(accountId, false);
        return account.0;
    };
    public shared(msg) func update_balance(_token: ?EthAddress, _account : Account) : async {
        #Ok : Minter.UpdateBalanceResult; 
        #Err : Minter.ResultError;
    }{
        let __start = Time.now();
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            return #Err(#GenericError({code = 400; message = "400: The system has been suspended!"}))
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("403: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        assert(depositMethod == 1 or depositMethod == 3);
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        // };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        let accountId = _accountId(_account.owner, _account.subaccount);
        if (not(_dosCheck(accountId, 15)) or not(_dosCheck(_accountId(msg.caller, null), 15))){
            return #Err(#GenericError({code = 400; message = "400: The network is busy, please try again later!"}))
        };
        _setLatestVisitTime(msg.caller);
        let res = await* _depositNotify(_token, _account);
        lastExecutionDuration := Time.now() - __start;
        if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
        return res;
    };
    /// Deposit Method : 2
    public shared(msg) func claim(_account : Account, _txHash: TxHash, _signature: [Nat8]) : async {
        #Ok : BlockHeight; 
        #Err : Minter.ResultError;
    }{
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            return #Err(#GenericError({code = 400; message = "400: The system has been suspended!"}))
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("403: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        assert(depositMethod == 2 or depositMethod == 3);
        assert(_txHash.size() == 66); // text
        assert(_signature.size() == 64 or _signature.size() == 65);
        let accountId = _accountId(_account.owner, _account.subaccount);
        //let tokenId = _toLower(Option.get(_token, eth_));
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        if (not(_dosCheck(accountId, 15)) or not(_dosCheck(_accountId(msg.caller, null), 15))){
            return #Err(#GenericError({code = 400; message = "400: The network is busy, please try again later!"}))
        };
        _setLatestVisitTime(msg.caller);
        let txHash = _toLower(_txHash);
        if (_isConfirmedTxn(txHash) or _isPendingTxn(txHash)){ // important!
            return #Err(#GenericError({ message = "TxHash already exists."; code = 402 }))
        }else{
            // New claiming
            _putPendingDepositTxn(_account, txHash, _signature, null);
            _putDepositTxn(_account, txHash, _signature, #Pending, null, null);
            let blockIndex = _putEvent(#claimDeposit({account = _account; txHash = txHash; signature = ABI.toHex(_signature)}), ?accountId);
            await* _method2TxnNotify(_account, txHash);
            return #Ok(blockIndex);
        };
    };
    /// Retrieve
    public query func get_withdrawal_account(_account : Account) : async Minter.Account{
        // assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        return {owner=Principal.fromActor(this); subaccount=?Blob.toArray(accountId)};
    };

    public shared(msg) func retrieve(_token: ?EthAddress, _address: EthAddress, _amount: Wei, _sa: ?[Nat8]) : async { 
        #Ok : Minter.RetrieveResult; //{ block_index : Nat64 };
        #Err : Minter.ResultError;
    }{
        let __start = Time.now();
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            return #Err(#GenericError({code = 400; message = "400: The system has been suspended!"}))
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("403: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        let accountId = _accountId(msg.caller, _sa);
        if (not(_dosCheck(accountId, 15)) or not(_dosCheck(_accountId(msg.caller, null), 15))){
            return #Err(#GenericError({code = 400; message = "400: The network is busy, please try again later!"}))
        };
        _setLatestVisitTime(msg.caller);
        let account: Minter.Account = {owner=msg.caller; subaccount=_sa};
        let withdrawalIcrc1Account: ICRC1.Account = {owner=Principal.fromActor(this); subaccount=?accountId};
        let mainAccount: Account = {owner = Principal.fromActor(this); subaccount = null };
        let toAddress = _toLower(_address);
        if (Text.size(_address) != 42){
            return #Err(#GenericError({code = 402; message="402: Address is not available."}));
        };
        if (List.size(pendingRetrievals) >= MAX_PENDING_RETRIEVALS){
            return #Err(#GenericError({code = 402; message="402: There are too many retrieval operations and the system is busy, please try again later."}));
        };
        let tokenId = _toLower(Option.get(_token, eth_));
        if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let _gasPrice = await* _fetchGasPrice();
        };
        let gasFee = _getEthGas(tokenId); // for ETH or ERC20
        let ckFee = _getCkFee(tokenId); // {eth; token} Wei 
        //AmountTooLow
        var sendingAmount = _amount;
        var sendingFee: Wei = 0;
        if (sendingAmount > ckFee.token and sendingAmount >= _getTokenMinAmount(tokenId)){
            sendingFee := ckFee.token;
            sendingAmount -= ckFee.token;
        }else{
            return #Err(#GenericError({code = 402; message="402: The amount is less than the gas or the minimum value."}));
        };
        //Insufficient burning balance
        let ckLedger = _getCkLedger(tokenId);
        let balance = await ckLedger.icrc1_balance_of(withdrawalIcrc1Account);
        if (balance < _amount){
            return #Err(#GenericError({code = 402; message="402: Insufficient funds. (balance of withdrawal account is "# Nat.toText(balance) #")"}));
        };
        //Insufficient pool balance
        if (_getBalance(mainAccount, tokenId) < _amount){
            return #Err(#GenericError({code = 402; message="402: Insufficient pool balance."}));
        };
        //Insufficient fee balance
        if (_getFeeBalance(eth_) < gasFee.maxFee){
            return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
        };
        //Burn
        switch(await* _burnCkToken2(tokenId, accountId, _address, _amount, account)){
            case(#Ok(height)){
                let (txi, toid) = _ictcSendNativeToken(account, tokenId, _amount, gasFee, ckFee, toAddress, height);
                // await* _ictcSagaRun(toid, false);
                let _f = _getSaga().run(toid);
                lastExecutionDuration := Time.now() - __start;
                if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
                ignore _putEvent(#withdraw({txIndex = txi; toid = toid; account = account; address = toAddress; token = tokenId; amount = sendingAmount; fee = ?sendingFee}), ?accountId);
                return #Ok({ 
                    blockIndex = Nat.sub(blockIndex, 1); 
                    amount = sendingAmount; 
                    retrieveFee = ckFee.token;
                    txIndex = txi;
                    toid = toid;
                });
            };
            case(#Err(#InsufficientFunds({ balance }))){
                return #Err(#GenericError({ code = 401; message="401: Insufficient balance when burning token.";}));
            };
            case(_){
                return #Err(#GenericError({ code = 401; message = "401: Error on burning token";}));
            };
        };
    };
    public shared(msg) func cover_tx(_txi: TxIndex, _sa: ?[Nat8]) : async ?BlockHeight{
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     throw Error.reject("405: IC network is busy, please try again later.");
        // };
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("403: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        let accountId = _accountId(msg.caller, _sa);
        if (not(_dosCheck(accountId, 5)) or not(_dosCheck(_accountId(msg.caller, null), 5))){
            throw Error.reject("400: The network is busy, please try again later!");
        };
        _setLatestVisitTime(msg.caller);
        assert((_onlyTxCaller(accountId, _txi) and _notPaused()) or _onlyOwner(msg.caller));
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                let coveredTs = Option.get(cts, ts);
                if (_now() < coveredTs + 30*60){ // 30 minuts
                    throw Error.reject("400: Please do this 30 minutes after the last status update. Last Updated: " # Nat.toText(coveredTs) # " (timestamp).");
                };
                if (Array.size(tx.txHash) > 5 and not(_onlyOwner(msg.caller))){
                    throw Error.reject("400: Covering the transaction can be submitted up to 5 times.");
                };
            };
            case(_){};
        };
        await* _syncTxStatus(_txi, true);
        return await* _coverTx(_txi, false, ?true, 0, true, true);
    };
    /// Query Functions
    public query func get_minter_address() : async (EthAddress, Nonce){
        return _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
    };
    public query func get_minter_info() : async MinterInfo{
        return {
            address = _getEthAddressQuery(_accountId(Principal.fromActor(this), null)).0;
            isDebug = app_debug;
            version = version_;
            paused = paused;
            owner = owner;
            minConfirmations = minConfirmations;
            minRpcConfirmations = minRpcConfirmations;
            depositMethod = depositMethod;
            chainId = ck_chainId;
            network = ckNetworkName;
            symbol = ckNetworkSymbol;
            decimals = ckNetworkDecimals;
            blockSlot = ckNetworkBlockSlot;
            syncBlockNumber = _getBlockNumber();
            gasPrice = ck_gasPrice/* + PRIORITY_FEE_PER_GAS*/;
            pendingDeposits = Trie.size(deposits);
            pendingRetrievals = List.size(pendingRetrievals);
            countMinting = countMinting;
            totalMintingAmount = totalMinting; // USDT
            countRetrieval = countRetrieval;
            totalRetrievalAmount = totalRetrieval; // USDT
        };
    };
    public query func get_depositing_all(_token: {#all; #eth; #token:EthAddress}, _account: ?Account): async 
    [(depositingBalance: Wei, txIndex: ?TxIndex, tx: ?Minter.TxStatus)]{
        var _tokenId: ?EthAddress = null; 
        switch(_token){
            case(#token(v)){ _tokenId := ?_toLower(v); };
            case(#eth){ _tokenId := ?eth_; };
            case(_){};
        };
        var res: [(depositingBalance: Wei, txIndex: ?TxIndex, tx: ?Minter.TxStatus)] = [];
        switch(_account){
            case(?(account)){
                let accountId = _accountId(account.owner, account.subaccount);
                let ?(txi) = _getDepositingTxIndex(accountId) else { return [] };
                switch(_getTx(txi)){
                    case(?(tx)){
                        if (_token == #all or ?tx.tokenId == _tokenId){
                            res := Tools.arrayAppend(res, [(_getBalance(tx.account, tx.tokenId), ?txi, ?tx)]);
                        };
                    };
                    case(_){};
                };
            };
            case(_){
                for ((accountId, txi) in Trie.iter(deposits)){
                    switch(_getTx(txi)){
                        case(?(tx)){
                            if (_token == #all or ?tx.tokenId == _tokenId){
                                res := Tools.arrayAppend(res, [(_getBalance(tx.account, tx.tokenId), ?txi, ?tx)]);
                            };
                        };
                        case(_){};
                    };
                };
            };
        };
        return res;
    };
    public query func get_mode2_pending_deposit_txn(_txHash: TxHash) : async ?Minter.PendingDepositTxn{
        return _getPendingDepositTxn(_toLower(_txHash));
    };
    public query func get_mode2_pending_all(_token: {#all; #eth; #token:EthAddress}, _account: ?Account) : async 
    [(txn: Minter.DepositTxn, updatedTs: Timestamp, verified: Bool)]{
        var _tokenId: ?EthAddress = null; 
        switch(_token){
            case(#token(v)){ _tokenId := ?_toLower(v); };
            case(#eth){ _tokenId := ?eth_; };
            case(_){};
        };
        var res: [(Minter.DepositTxn, Timestamp, Bool)] = [];
        for ((txHashId, (txHash, account, signature, isVerified, ts, optToid)) in Trie.iter(pendingDepositTxns)){
            switch(_getDepositTxn(txHash)){
                case(?(txn, updatedTs)){
                    var txnTokenId: ?EthAddress = switch(txn.transfer){ case(?trans){ ?trans.token }; case(_){ null } }; 
                    if ((Option.isNull(_tokenId) or _tokenId == txnTokenId) and (Option.isNull(_account) or _account == ?txn.account)){
                        res := Tools.arrayAppend(res, [(txn, updatedTs, isVerified)]);
                    };
                };
                case(_){};
            };
        };
        return res;
    };
    public query func get_mode2_deposit_txn(_txHash: TxHash) : async ?(DepositTxn, Timestamp){
        return _getDepositTxn(_toLower(_txHash));
    };
    public query func get_pool_balance(_token: ?EthAddress): async Wei{
        let tokenId = _toLower(Option.get(_token, eth_));
        let accountId = _accountId(Principal.fromActor(this), null);
        return _getBalance({owner = Principal.fromActor(this); subaccount = null }, tokenId);
    };
    public query func get_fee_balance(_token: ?EthAddress): async Wei{
        let tokenId = _toLower(Option.get(_token, eth_));
        return _getFeeBalance(tokenId);
    };
    public query func get_tx(_txi: TxIndex) : async ?Minter.TxStatus{
        return _getTx(_txi);
    }; 
    public query func get_retrieval(_txi: TxIndex) : async ?Minter.RetrieveStatus{  
        switch(Trie.get(retrievals, keyn(_txi), Nat.equal)){
            case(?(status)){
                return ?status;
            };
            case(_){
                return null;
            };
        };
    };
    public query func get_retrieval_list(_account: Account) : async [Minter.RetrieveStatus]{  //latest 1000 records
        let accountId = _accountId(_account.owner, _account.subaccount);
        switch(Trie.get(withdrawals, keyb(accountId), Blob.equal)){
            case(?(list)){
                var data = list;
                if (List.size(list) > 1000){
                    data := List.split(1000, list).0;
                };
                return List.toArray(List.mapFilter<TxIndex, Minter.RetrieveStatus>(data, func (_txi: TxIndex): ?Minter.RetrieveStatus{
                    Trie.get(retrievals, keyn(_txi), Nat.equal);
                }));
            };
            case(_){
                return [];
            };
        };
    };
    public query func get_retrieving_all(_token: {#all; #eth; #token:EthAddress}, _account: ?Account) : async [(TxIndex, Minter.TxStatus, Timestamp)]{
        var tokenId = eth_; 
        switch(_token){
            case(#token(v)){ tokenId := _toLower(v); };
            case(_){};
        };
        let account = Option.get(_account, {owner=Principal.fromActor(this); subaccount=null});
        let accountId = _accountId(account.owner, account.subaccount);
        return List.toArray(List.mapFilter<TxIndex, (TxIndex, Minter.TxStatus, Timestamp)>(pendingRetrievals, func (_txi: TxIndex): ?(TxIndex, Minter.TxStatus, Timestamp){
            switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
                case(?item){ 
                    let itemAccountId = _accountId(item.0.account.owner, item.0.account.subaccount);
                    if ((_token == #all or item.0.tokenId == tokenId) and (Option.isNull(_account) or itemAccountId == accountId)){ 
                        ?(_txi, item.0, item.1)
                    }else{ null };
                };
                case(_){ null };
            };
        }));
    };
    public query func get_ck_tokens() : async [(EthAddress, TokenInfo)]{
        return Iter.toArray(Trie.iter(tokens));
    };
    public query func get_event(_blockIndex: BlockHeight) : async ?(Event, Timestamp){
        return ICEvents.getEvent(blockEvents, _blockIndex);
    };
    public query func get_event_first_index() : async BlockHeight{
        return firstBlockIndex;
    };
    public query func get_events(_page: ?ListPage, _size: ?ListSize) : async TrieList<BlockHeight, (Event, Timestamp)>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        return ICEvents.trieItems2<(Event, Timestamp)>(blockEvents, firstBlockIndex, blockIndex, page, size);
    };
    public query func get_account_events(_accountId: AccountId) : async [(Event, Timestamp)]{ //latest 1000 records
        return ICEvents.getAccountEvents<Event>(blockEvents, accountEvents, _accountId);
    };
    public query func get_event_count() : async Nat{
        return blockIndex;
    };
    public query func get_rpc_logs(_page: ?ListPage, _size: ?ListSize) : async TrieList<RpcId, RpcLog>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        let res = ICEvents.trieItems2<RpcLog>(ck_rpcLogs, firstRpcId, rpcId, page, size);
        let data = Array.map<(RpcId, RpcLog), (RpcId, RpcLog)>(res.data, func(t: (RpcId, RpcLog)): (RpcId, RpcLog){
            (t.0, { url = "***" # ETHCrypto.strRight(t.1.url, 4); time = t.1.time; input = t.1.input; result = t.1.result; err = t.1.err });
        });
        return {data = data; total = res.total; totalPage = res.totalPage; };
    };
    public query func get_rpc_log(_rpcId: RpcId) : async ?RpcLog{
        switch(Trie.get(ck_rpcLogs, keyn(_rpcId), Nat.equal)){
            case(?(item)){
                return ?{
                    url = "***" # ETHCrypto.strRight(item.url, 4); time = item.time; input = item.input; result = item.result; err = item.err
                };
            };
            case(_){ return null };
        };

    };
    public query func get_rpc_requests(_page: ?ListPage, _size: ?ListSize) : async TrieList<RpcRequestId, RpcRequestConsensus>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        return ICEvents.trieItems2<RpcRequestConsensus>(ck_rpcRequests, firstRpcRequestId, rpcRequestId, page, size);
    };
    public query func get_rpc_request(_rpcRequestId: RpcRequestId) : async ?RpcRequestConsensus{
        return Trie.get(ck_rpcRequests, keyn(_rpcRequestId), Nat.equal);
    };
    public query func get_rpc_request_temps(): async [(RpcRequestId, (confirmationStats: [([Value], Nat)], ts: Timestamp))]{
        return Trie.toArray<RpcRequestId, ([([Value], Nat)], Timestamp), (RpcRequestId, ([([Value], Nat)], Timestamp))>(ck_rpcRequestConsensusTemps, 
            func (k: RpcRequestId, v: ([([Value], Nat)], Timestamp)): (RpcRequestId, ([([Value], Nat)], Timestamp)){
                return (k, v);
            });
    };

    /* ===========================
      Keeper section
    ============================== */
    // variant{put = record{"RPC1"; "..."; variant{Available}}}, null
    public shared(msg) func keeper_set_rpc(_act: {#remove; #put:(name: Text, url: Text, status: {#Available; #Unavailable})}, _sa: ?Sa) : async Bool{ 
        let accountId = _accountId(msg.caller, _sa);
        if (not(_onlyKeeper(accountId))){
            throw Error.reject("500: You don't have permissions of Keeper.");
        };
        switch(_act){
            case(#remove){
                ck_rpcProviders := Trie.remove(ck_rpcProviders, keyb(accountId), Blob.equal).0;
            };
            case(#put(name, url, status)){
                if (not(_isRpcDomainWhitelist(url))){
                    throw Error.reject("500: The RPC domain is not whitelisted.");
                };
                switch(Trie.get(ck_rpcProviders, keyb(accountId), Blob.equal)){
                    case(?(provider)){
                        ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(accountId), Blob.equal, {
                            name = name; 
                            url = url; 
                            keeper = accountId;
                            status = status; 
                            calls = provider.calls; 
                            errors = provider.errors; 
                            preHealthCheck = provider.preHealthCheck;
                            healthCheck = {time=0; calls=0; errors=0; recentPersistentErrors=?0};
                            latestCall = provider.latestCall;
                        }).0;
                    };
                    case(_){
                        ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(accountId), Blob.equal, {
                            name = name; 
                            url = url; 
                            keeper = accountId;
                            status = status; 
                            calls = 0; 
                            errors = 0; 
                            preHealthCheck = {time=0; calls=0; errors=0; recentPersistentErrors=?0};
                            healthCheck = {time=0; calls=0; errors=0; recentPersistentErrors=?0};
                            latestCall = 0;
                        }).0;
                    };
                };
            };
        };
        return true;
    };
    public query func get_keepers(): async TrieList<AccountId, Keeper>{
        let _res = trieItems<AccountId, Keeper>(ck_keepers, 1, 2000);
    };
    public query func get_rpc_providers(): async TrieList<AccountId, RpcProvider>{
        let res = trieItems<AccountId, RpcProvider>(ck_rpcProviders, 1, 2000);
        return {
            data = Array.map<(AccountId, RpcProvider), (AccountId, RpcProvider)>(res.data, func (t:(AccountId, RpcProvider)): (AccountId, RpcProvider){
                (t.0, {
                    name = t.1.name; 
                    url = _getRpcDomain(t.1.url) # "***" # ETHCrypto.strRight(t.1.url, 4); 
                    keeper = t.1.keeper; 
                    status = t.1.status; 
                    calls = t.1.calls; 
                    errors = t.1.errors; 
                    preHealthCheck = t.1.preHealthCheck; 
                    healthCheck = t.1.healthCheck; 
                    latestCall = t.1.latestCall; 
                })
            }); 
            total = res.total; 
            totalPage = res.totalPage;
        };
    };

    /* ===========================
      KYT section
    ============================== */
    private let chainName = ckNetworkName;
    private func _putAddressAccount(_tokenId: KYT.Address, _address: KYT.Address, _account: KYT.Account) : (){
        if (Principal.isController(_account.owner)){
            return ();
        };
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let tokenBlob = Blob.fromArray(_getEthAccount(_tokenId));
        let res = KYT.putAddressAccount(kyt_accountAddresses, kyt_addressAccounts, (chainName, tokenBlob, _toLower(_address)), (tokenInfo.ckLedgerId, _account));
        kyt_accountAddresses := res.0;
        kyt_addressAccounts := res.1;
    };
    private func _getAccountAddress(_accountId: KYT.AccountId) : ?[KYT.ChainAccount]{
        return KYT.getAccountAddress(kyt_accountAddresses, _accountId);
    };
    private func _getAddressAccount(_address: KYT.Address) : ?[KYT.ICAccount]{
        return KYT.getAddressAccount(kyt_addressAccounts, _toLower(_address));
    };
    private func _putTxAccount(_tokenId: KYT.Address, _txHash: KYT.TxHash, _address: KYT.Address, _account: KYT.Account) : (){
        if (Principal.isController(_account.owner)){
            return ();
        };
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let tokenBlob = Blob.fromArray(_getEthAccount(_tokenId));
        kyt_txAccounts := KYT.putTxAccount(kyt_txAccounts, _toLower(_txHash), (chainName, tokenBlob, _toLower(_address)), (tokenInfo.ckLedgerId, _account));
    };
    private func _getTxAccount(_txHash: KYT.TxHash) : ?[(KYT.ChainAccount, KYT.ICAccount)]{
        return KYT.getTxAccount(kyt_txAccounts, _toLower(_txHash));
    };

    public query func get_cached_address(_accountId : KYT.AccountId) : async ?[KYT.ChainAccount]{
        return _getAccountAddress(_accountId);
    };
    public query func get_cached_account(_address : KYT.Address) : async ?[KYT.ICAccount]{
        return _getAddressAccount(_address);
    };
    public query func get_cached_tx_account(_txHash: KYT.TxHash) : async ?[(KYT.ChainAccount, KYT.ICAccount)]{
        return _getTxAccount(_txHash);
    };

    /* ===========================
      Management section
    ============================== */
    public query func getOwner() : async Principal{  
        return owner;
    };
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        ignore _putEvent(#changeOwner({newOwner = _newOwner}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func setPause(_paused: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        paused := _paused;
        if (paused){
            ignore _putEvent(#suspend({message = ?"Suspension from DAO"}), ?_accountId(owner, null));
        }else{
            ignore _putEvent(#start({message = ?"Starting from DAO"}), ?_accountId(owner, null));
        };
        return true;
    };
    public shared(msg) func setMinConfirmations(_minConfirmations: Nat) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        minConfirmations := Nat.max(_minConfirmations, 5);
        ignore _putEvent(#config({setting = #minConfirmations(_minConfirmations)}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func setMinRpcConfirmations(_minConfirmations: Nat) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        minRpcConfirmations := Nat.max(_minConfirmations, 1);
        ignore _putEvent(#config({setting = #minRpcConfirmations(_minConfirmations)}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func setDepositMethod(_depositMethod: Nat8) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        depositMethod := _depositMethod;
        ignore _putEvent(#config({setting = #depositMethod(_depositMethod)}), ?_accountId(owner, null));
        return true;
    };

    public shared(msg) func addRpcWhitelist(_rpcDomain: Text) : async (){
        assert(_onlyOwner(msg.caller));
        _addRpcDomainWhitelist(_rpcDomain);
    };
    public shared(msg) func removeRpcWhitelist(_rpcDomain: Text) : async (){
        assert(_onlyOwner(msg.caller));
        _removeRpcDomainWhitelist(_rpcDomain);
        _removeProviders(_rpcDomain);
    };
    // record{owner=principal ""; subaccount=null}, opt "Keeper1", null, variant{Normal}
    public shared(msg) func setKeeper(_account: Account, _name: ?Text, _url: ?Text, _status: {#Normal; #Disabled}) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        switch(Trie.get(ck_keepers, keyb(accountId), Blob.equal)){
            case(?(keeper)){
                ck_keepers := Trie.put(ck_keepers, keyb(accountId), Blob.equal, {
                    name = Option.get(_name, keeper.name); 
                    url = Option.get(_url, keeper.url); 
                    account = _account;
                    status = _status;
                    balance = keeper.balance;
                }).0;
            };
            case(_){
                ck_keepers := Trie.put(ck_keepers, keyb(accountId), Blob.equal, {
                    name = Option.get(_name, ""); 
                    url = Option.get(_url, ""); 
                    account = _account;
                    status = _status;
                    balance = 0;
                }).0;
            };
        };
        ignore _putEvent(#config({setting = #setKeeper({account=_account; name=Option.get(_name, ""); url=Option.get(_url, ""); status=_status})}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func allocateRewards(_args: [{_account: Account; _value: Wei; _sendRetainedBalance: Bool}]) : async [(Account, Bool)]{ 
        assert(_onlyOwner(msg.caller));
        var res: [(Account, Bool)] = [];
        for ({_account; _value; _sendRetainedBalance} in _args.vals()){
            let accountId = _accountId(_account.owner, _account.subaccount);
            switch(Trie.get(ck_keepers, keyb(accountId), Blob.equal)){
                case(?(keeper)){
                    let value = _value + (if (_sendRetainedBalance) { keeper.balance }else{ 0 });
                    assert(value + _getEthGas(eth_).maxFee < _getFeeBalance(eth_));
                    if (_sendRetainedBalance){
                        ck_keepers := Trie.put(ck_keepers, keyb(accountId), Blob.equal, {
                            name = keeper.name; 
                            url = keeper.url; 
                            account = keeper.account;
                            status = keeper.status;
                            balance = 0;
                        }).0;
                    };
                    try{
                        await* _sendFromFeeBalance(_account, value);
                        res := Tools.arrayAppend(res, [(_account, true)]);
                    }catch(e){
                        res := Tools.arrayAppend(res, [(_account, false)]);
                    };
                };
                case(_){
                    res := Tools.arrayAppend(res, [(_account, false)]);
                };
            };
        };
        return res;
    };
    public shared(msg) func updateRpc(_account: Account, _act: {#remove; #set: {#Available; #Unavailable}}) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        switch(_act){
            case(#remove){
                ck_rpcProviders := Trie.remove(ck_rpcProviders, keyb(accountId), Blob.equal).0;
            };
            case(#set(status)){
                switch(Trie.get(ck_rpcProviders, keyb(accountId), Blob.equal)){
                    case(?(provider)){
                        ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(accountId), Blob.equal, {
                            name = provider.name; 
                            url = provider.url; 
                            keeper = accountId;
                            status = status; 
                            calls = provider.calls; 
                            errors = provider.errors; 
                            preHealthCheck = provider.preHealthCheck;
                            healthCheck = provider.healthCheck;
                            latestCall = provider.latestCall;
                        }).0;
                    };
                    case(_){};
                };
            };
        };
        ignore _putEvent(#config({setting = #updateRpc({keeper=_account; operation=_act })}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func sync() : async (Nat, Nat, Nat, Text, Nat){
        assert(_onlyOwner(msg.caller));
        ck_chainId := await* _fetchChainId();
        ck_gasPrice := await* _fetchGasPrice();
        ck_ethBlockNumber := (await* _fetchBlockNumber(), _now());
        let selfAddressInfo = await* _getEthAddress(_accountId(Principal.fromActor(this), null), true);
        return (ck_chainId, ck_gasPrice, ck_ethBlockNumber.0, selfAddressInfo.0, selfAddressInfo.1);
    };
    public shared(msg) func confirmRetrievalTx(_txIndex: TxIndex): async Bool{
        assert(_onlyOwner(msg.caller));
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.txType == #Withdraw and tx.status == #Submitted){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    _updateTx(_txIndex, {
                        fee = null;
                        amount = null;
                        nonce = null;
                        toids = null;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcRequestId = null;
                        kytRequestId = null;
                        status = ?#Confirmed;
                        ts = null;
                    }, null);
                    _removeRetrievingTxIndex(_txIndex);
                    ignore _putEvent(#withdrawResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=tx.amount})), ?accountId);
                    _stats(tx.tokenId, #Retrieval, tx.amount);
                    return true;
                }else{
                    return false;
                };
            };
            case(_){
                return false;
            };
        };
    };
    public shared(msg) func rebuildAndResend(_txi: TxIndex, _nonce: {#Remain; #Reset: {spentTxHash: TxHash}}, _refetchGasPrice: Bool, _amountSub: Wei, _autoAdjust: Bool) : async ?BlockHeight{
        // WARNING: Ensure that previous transactions have failed before rebuilding the transaction.
        // WARNING: If you want to reset the nonce, you need to make sure that the original nonce is used by another transaction, such as a blank transaction.
        // Create a new ICTC transaction order (new toid).
        assert(_onlyOwner(msg.caller));
        var _resetNonce : Bool = false;
        switch(_nonce){
            case(#Remain){};
            case(#Reset(arg)){
                let (success1, txn, height1, confirmation1, txNonce, returns1) = await* _fetchTxn(arg.spentTxHash);
                let (success2, height2, confirmation2, returns2) = await* _fetchTxReceipt(arg.spentTxHash);
                assert(success1 and success2); //#1#//
                switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
                    case(?(tx, ts, cts)){
                        assert(tx.nonce == txNonce); //#2#//
                    };
                    case(_){
                        assert(false); //#3#//
                    };
                };
                _resetNonce := true;
            };
        }; 
        await* _syncTxStatus(_txi, true);
        return await* _coverTx(_txi, _resetNonce, ?_refetchGasPrice, _amountSub, _autoAdjust, not(_resetNonce));
    };
    public shared(msg) func rebuildAndContinue(_txi: TxIndex, _toid: SagaTM.Toid, _nonce: {#Remain; #Reset: {spentTxHash: TxHash}}) : async ?BlockHeight{
        // Add compensation tasks to the original ICTC transaction order (original toid).
        assert(_onlyOwner(msg.caller));
        var _resetNonce : Bool = false;
        switch(_nonce){
            case(#Remain){
                switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
                    case(?(tx, ts, cts)){
                        if (Option.isNull(tx.nonce)){
                            _resetNonce := true;
                        };
                    };
                    case(_){};
                };
            };
            case(#Reset(arg)){
                let (success1, txn, height1, confirmation1, txNonce, returns1) = await* _fetchTxn(arg.spentTxHash);
                let (success2, height2, confirmation2, returns2) = await* _fetchTxReceipt(arg.spentTxHash);
                assert(success1 and success2); //#1#//
                switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
                    case(?(tx, ts, cts)){
                        assert(tx.nonce == txNonce); //#2#//
                    };
                    case(_){
                        assert(false); //#3#//
                    };
                };
                _resetNonce := true;
            };
        }; 
        await* _syncTxStatus(_txi, true);
        assert(_onlyBlocking(_toid));
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){ 
                if (tx.status != #Failure and tx.status != #Confirmed and Option.isSome(Array.find(tx.toids, func(t: Nat): Bool{ t == _toid }))){
                    let args: Minter.UpdateTxArgs = {
                        fee = null;
                        amount = null;
                        nonce = null;
                        toids = null;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcRequestId = null;
                        kytRequestId = null;
                        status = ?#Building;
                        ts = ?_now();
                    };
                    _updateTx(_txi, args, ?_now());
                    // ICTC compensate
                    let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
                    let saga = _getSaga();
                    saga.open(_toid);
                    var preTtid0: [Nat] = [];
                    if (_resetNonce){
                        let task0 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#getNonce(_txi, ?[_toid])), [], 0, null, null);
                        let ttid0 = saga.appendComp(_toid, 0, task0, null);
                        preTtid0 := [ttid0];
                    };
                    let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(_txi)), preTtid0, 0, null, null);
                    let ttid1 = saga.appendComp(_toid, 0, task1, null);
                    let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(_txi)), [ttid1], 0, null, null);
                    let ttid2 = saga.appendComp(_toid, 0, task2, null);
                    let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(_txi)), [ttid2], 0, null, null);
                    let ttid3 = saga.appendComp(_toid, 0, task3, null);
                    let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(_txi, false)), [ttid3], 0, ?txTaskAttempts, ?_txTaskInterval());
                    let _ttid4 = saga.appendComp(_toid, 0, task4, null);
                    saga.close(_toid);
                    await* _ictcSagaRun(_toid, true);
                    ignore await* _getSaga().complete(_toid, #Done);
                    // record event
                    return ?_putEvent(#continueTransaction({txIndex = _txi; toid = _toid; account = tx.account; preTxid=tx.txHash; updateTx = ?args}), ?_accountId(owner, null));
                }else{
                    throw Error.reject("402: The status of transaction is completed!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    public shared(msg) func resetNonce(_arg: {#latest; #pending}) : async Nonce{
        // WARNING: Don't reset nonce when the system is sending transactions normally.
        assert(_onlyOwner(msg.caller));
        assert(not(_notPaused()));
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccountId);
        let nonce = await* _fetchAccountNonce(mainAddress, _arg);
        _setEthAccount(mainAccountId, mainAddress, nonce);
        return nonce;
    };
    public shared(msg) func sendBlankTx(_nonce: Nat) : async SagaTM.Toid{
        assert(_onlyOwner(msg.caller));
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccountId);
        let saga = _getSaga();
        let toid : Nat = saga.create("blank_txn", #Forward, null, null);
        let txStatus: Minter.TxStatus = {
            txType = #Withdraw;
            tokenId = eth_;
            account = {owner = msg.caller; subaccount=null};
            from = mainAddress;
            to = mainAddress;
            amount = 0;
            fee = _getEthGas(eth_);
            nonce = ?_nonce;
            toids = [toid];
            txHash = [];
            tx = null;
            rawTx = null;
            signedTx = null;
            receipt = null;
            rpcRequestId = null;
            kytRequestId = null;
            status = #Building;
        };
        transactions := Trie.put(transactions, keyn(txIndex), Nat.equal, (txStatus, _now(), ?_now())).0;
        let txi = txIndex;
        txIndex += 1; 

        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
        // let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
        // let ttid1 = saga.push(toid, task1, null, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(txi)), [], 0, null, null);
        let _ttid2 = saga.push(toid, task2, null, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(txi)), [], 0, null, null);
        let _ttid3 = saga.push(toid, task3, null, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(txi)), [], 0, null, null);
        let _ttid4 = saga.push(toid, task4, null, null);
        let task5 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(txi, false)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let _ttid5 = saga.push(toid, task5, null, null);
        saga.close(toid);
        await* _ictcSagaRun(toid, false);
        return toid;
    };
    public shared(msg) func updateMinterBalance(_token: ?EthAddress, _surplusToFee: Bool) : async {pre: Minter.BalanceStats; post: Minter.BalanceStats; shortfall: Wei}{
        // Warning: To ensure the accuracy of the balance update, it is necessary to wait for the minimum required number of block confirmations before calling this function after suspending the contract operation.
        // WARNING: If you want to attribute the surplus tokens to the FEE balance, you need to make sure all claim operations for the cross-chain transactions have been completed.
        assert(_onlyOwner(msg.caller));
        assert(not(_notPaused()));
        assert(_ictcAllDone());
        let tokenId = _toLower(Option.get(_token, eth_));
        let mainAccount = {owner = Principal.fromActor(this); subaccount = null };
        let preBalances = await* _getMinterBalance(_token, false);
        var postBalances = preBalances;
        let nativeBalance = preBalances.nativeBalance;
        var ckTotalSupply = preBalances.totalSupply;
        var ckFeetoBalance = preBalances.feeBalance;
        var shortfall: Wei = 0;
        if (_ictcAllDone()){
            if (ckTotalSupply > nativeBalance){
                var value = Nat.sub(ckTotalSupply, nativeBalance);
                if (ckFeetoBalance < 1000000 and ckFeetoBalance < value){
                    shortfall := value;
                    value := 0;
                } else if (ckFeetoBalance >= 1000000 and ckFeetoBalance < value){
                    let temp = Nat.sub(ckFeetoBalance, 1000000);
                    shortfall := Nat.sub(value, temp);
                    value := temp;
                };
                ckTotalSupply -= Nat.min(ckTotalSupply, value);
                ckFeetoBalance -= Nat.min(ckFeetoBalance, value);
                ignore _burnCkToken(tokenId, Blob.fromArray(sa_one), value, {owner = Principal.fromActor(this); subaccount = ?sa_one }, ?"burn_ck_token(update)");
            } else if (ckTotalSupply < nativeBalance and _surplusToFee){
                let value = Nat.sub(nativeBalance, ckTotalSupply);
                ckTotalSupply += value;
                ckFeetoBalance += value;
                ignore _mintCkToken(tokenId, {owner = Principal.fromActor(this); subaccount = ?sa_one }, value, null, ?"mint_ck_token(update)");
            };
            _setFeeBalance(tokenId, ckFeetoBalance);
            _setBalance(mainAccount, tokenId, Nat.sub(ckTotalSupply, ckFeetoBalance));
            postBalances := {nativeBalance = nativeBalance; totalSupply = ckTotalSupply; minterBalance = _getBalance(mainAccount, tokenId); feeBalance = ckFeetoBalance};
            await* _ictcSagaRun(0, false);
        };
        return {pre = preBalances; post = postBalances; shortfall = shortfall};
    };
    public shared(msg) func setTokenInfo(_token: ?EthAddress, _info: TokenInfo) : async (){
        // Warning: Directly modifying token information may introduce other exceptions.
        assert(_onlyOwner(msg.caller));
        let tokenId = _toLower(Option.get(_token, eth_));
        tokens := Trie.put(tokens, keyt(tokenId), Text.equal, _info).0;
        ignore _putEvent(#config({setting = #setToken({token=tokenId; info=_info})}), ?_accountId(owner, null));
    };
    public shared(msg) func setTokenFees(_token: ?EthAddress, _args: {minAmount: Wei; fixedFee: Wei; gasLimit: Nat; ethRatio: ?Wei; totalSupply: ?Nat;}) : async Bool{
        assert(_onlyOwner(msg.caller));
        let tokenId = _toLower(Option.get(_token, eth_));
        switch(Trie.get(tokens, keyt(tokenId), Text.equal)){
            case(?(token)){
                let tokenInfo : TokenInfo = {
                    tokenId = tokenId;
                    std = token.std;
                    symbol = token.symbol;
                    decimals = token.decimals;
                    totalSupply = switch(_args.totalSupply){ case(?(v)){ ?v }; case(_){ token.totalSupply } };
                    minAmount = _args.minAmount;
                    ckSymbol = token.ckSymbol;
                    ckLedgerId = token.ckLedgerId;
                    fee = {
                        fixedFee = _args.fixedFee;
                        gasLimit = _args.gasLimit;
                        ethRatio = Option.get(_args.ethRatio, token.fee.ethRatio);
                    };
                    dexPair = token.dexPair;
                    dexPrice = token.dexPrice;
                };
                tokens := Trie.put(tokens, keyt(tokenId), Text.equal, tokenInfo).0;
                ignore _putEvent(#config({setting = #setToken({token=tokenId; info=tokenInfo})}), ?_accountId(owner, null));
                return true;
            };
            case(_){};
        };
        return false;
    };
    // ETH & Quote token: variant{ETH=record{quoteToken="0xefa83712d45ee530ac215b96390a663c01f2fee0";dexPair=principal "tkrhr-gaaaa-aaaak-aeyaq-cai"}}
    // Other tokens: variant{ERC20=record{tokenId="0x9813ad2cacba44fc8b099275477c9bed56c539cd";dexPair=principal "twv5a-raaaa-aaaak-aeycq-cai"}}
    public shared(msg) func setTokenDexPair(_token: {#ETH: {quoteToken: EthAddress; dexPair: Principal}; #ERC20: {tokenId: EthAddress; dexPair: Principal}}) : async Bool{
        assert(_onlyOwner(msg.caller));
        switch(_token){
            case(#ETH(args)){
                quoteToken := _toLower(args.quoteToken);
                await* _putTokenDexPair(eth_, ?args.dexPair);
                await* _updateTokenPrice(eth_);
                await* _updateTokenPrice(quoteToken);
                return true;
            };
            case(#ERC20(args)){
                await* _putTokenDexPair(_toLower(args.tokenId), ?args.dexPair);
                await* _updateTokenPrice(_toLower(args.tokenId));
                return true;
            };
        };
        return false;
    };
    public shared(msg) func setCkTokenWasm(_wasm: Blob, _version: Text) : async (){
        assert(_onlyOwner(msg.caller));
        assert(Option.isNull(Array.find(icrc1WasmHistory, func (t: ([Nat8], Text)): Bool{ _version == t.1 })));
        icrc1WasmHistory := Tools.arrayAppend([(Blob.toArray(_wasm), _version)], icrc1WasmHistory);
        if (icrc1WasmHistory.size() > 32){
            icrc1WasmHistory := Tools.slice(icrc1WasmHistory, 0, ?31);
        };
        ignore _putEvent(#config({setting = #setTokenWasm({version=_version; size=_wasm.size()})}), ?_accountId(owner, null));
    };
    public query func getCkTokenWasmVersion() : async (Text, Nat){ 
        let wasm = _getLatestIcrc1Wasm();
        return (wasm.1, wasm.0.size());
    };
    public query func getCkTokenWasmHistory(): async [(Text, Nat)]{
        return Array.map<([Nat8], Text), (Text, Nat)>(icrc1WasmHistory, func (t: ([Nat8], Text)): (Text, Nat){
            return (t.1, t.0.size());
        });
    };
    //opt "0xefa83712d45ee530ac215b96390a663c01f2fee0", "USDT", record{totalSupply=null; minAmount=10000000000000000; ckTokenFee=100000000000; fixedFee=1000000000000000; gasLimit=61000; ethRatio=1000000000}
    public shared(msg) func launchToken(_token: ?EthAddress, _rename: ?Text, _args: {
        totalSupply: ?Wei/*smallest_unit Token*/; 
        minAmount: Wei/*smallest_unit Token*/; 
        ckTokenFee: Wei/*smallest_unit Token*/; 
        fixedFee: Wei/*smallest_unit ETH*/; 
        gasLimit: Nat; 
        ethRatio: Wei/*1 Gwei ETH = ? smallest_unit Token */
    }) : async Principal{
        assert(_onlyOwner(msg.caller));
        let wasm = _getLatestIcrc1Wasm();
        assert(wasm.0.size() > 0);
        let account = {owner = Principal.fromActor(this); subaccount = null };
        let tokenId = _toLower(Option.get(_token, eth_));
        assert(Option.isNull(Trie.get(tokens, keyt(tokenId), Text.equal)));
        var std: {#ETH; #ERC20} = #ERC20;
        if (tokenId == eth_){
            std := #ETH;
        };
        let ic: IC.Self = actor("aaaaa-aa");
        Cycles.add<system>(INIT_CKTOKEN_CYCLES);
        let newCanister = await ic.create_canister({ settings = ?{
            freezing_threshold = null;
            controllers = ?[Principal.fromActor(this), Principal.fromText(blackhole_)];
            memory_allocation = null;
            compute_allocation = null;
        } });
        var tokenMetadata : {symbol: Text; decimals: Nat8 } = {symbol = ckNetworkSymbol; decimals = ckNetworkDecimals };
        if (std == #ERC20){
            tokenMetadata := await* _fetchERC20Metadata(tokenId);
        };
        var ckSymbol: Text = Option.get(_rename, tokenMetadata.symbol);
        var ckName: Text = ckSymbol # " on IC"; // ckNetworkName
        // if (std == #ETH){
        //     ckSymbol := "ic" # ckSymbol;
        // };
        let tokenInfo : TokenInfo = {
            tokenId = tokenId;
            std = std;
            symbol = tokenMetadata.symbol;
            decimals = tokenMetadata.decimals;
            totalSupply = _args.totalSupply;
            minAmount = _args.minAmount;
            ckSymbol = ckSymbol;
            ckLedgerId = newCanister.canister_id;
            fee = {
                fixedFee = _args.fixedFee;
                gasLimit = _args.gasLimit;
                ethRatio = _args.ethRatio;
            };
            dexPair = null;
            dexPrice = null;
        };
        tokens := Trie.put(tokens, keyt(tokenId), Text.equal, tokenInfo).0;
        await ic.install_code({
            arg = Blob.toArray(to_candid({ 
                totalSupply = 0; 
                decimals = tokenMetadata.decimals; 
                fee = _args.ckTokenFee; 
                name = ?ckName; 
                symbol = ?ckSymbol; 
                metadata = null; 
                founder = null;
            }: DRC20.InitArgs, app_debug));
            wasm_module = wasm.0;
            mode = #install; // #reinstall; #upgrade; #install
            canister_id = newCanister.canister_id;
        });
        //Set FEE_TO & Minter
        let ictokens = _getICTokens(tokenId);
        ignore await ictokens.ictokens_config({feeTo = ?Tools.principalToAccountHex(Principal.fromActor(this), ?sa_one)});
        ignore await ictokens.ictokens_addMinter(Principal.fromActor(this));
        ignore _putEvent(#config({setting = #launchToken({token=tokenId; symbol=tokenMetadata.symbol; icTokenCanisterId = newCanister.canister_id})}), ?_accountId(owner, null));
        cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, newCanister.canister_id);
        return newCanister.canister_id;
    };
    public shared(msg) func setTokenLogo(_canisterId: Principal, _logo: Text): async Bool{
        assert(_onlyOwner(msg.caller));
        let token = actor(Principal.toText(_canisterId)) : actor{ 
            drc20_metadata : shared query () -> async [{ content : Text; name : Text }];
            ictokens_setMetadata : shared ([{ content : Text; name : Text }]) -> async Bool; 
        };
        var metadata = await token.drc20_metadata();
        metadata := Array.filter(metadata, func (t: { content : Text; name : Text }): Bool{ t.name != "logo" });
        metadata := Tools.arrayAppend(metadata, [{ content = _logo; name = "logo" }]);
        return await token.ictokens_setMetadata(metadata);
    };
    public shared(msg) func upgradeToken(_canisterId: Principal, _version: Text): async (version: Text){
        assert(_onlyOwner(msg.caller));
        var wasm : [Nat8] = [];
        var version: Text = "";
        if (_version == "latest"){
            wasm := icrc1WasmHistory[0].0;
            version := icrc1WasmHistory[0].1;
        }else{
            switch(Array.find(icrc1WasmHistory, func (t: ([Nat8], Text)): Bool{ _version == t.1 })){
                case(?(w, v)){
                    wasm := w;
                    version := v;
                };
                case(_){ assert(false); };
            };
        };
        assert(wasm.size() > 0);
        let icrc1: ICRC1.Self = actor(Principal.toText(_canisterId));
        let decimals = await icrc1.icrc1_decimals();
        let fee = await icrc1.icrc1_fee();
        let name = await icrc1.icrc1_name();
        let symbol = await icrc1.icrc1_symbol();
        let ic: IC.Self = actor("aaaaa-aa");
        await ic.install_code({
            arg = Blob.toArray(to_candid({ 
                totalSupply = 0; 
                decimals = decimals; 
                fee = fee; 
                name = ?name; 
                symbol = ?symbol; 
                metadata = null; 
                founder = null;
            }: DRC20.InitArgs, app_debug));
            wasm_module = wasm;
            mode = #upgrade; // #reinstall; #upgrade; #install
            canister_id = _canisterId;
        });
        ignore _putEvent(#config({setting = #upgradeTokenWasm({symbol=symbol; icTokenCanisterId = _canisterId; version = version})}), ?_accountId(owner, null));
        return version;
    };
    public shared(msg) func removeToken(_token: ?EthAddress): async (){
        assert(_onlyOwner(msg.caller));
        let tokenId = _toLower(Option.get(_token, eth_));
        let tokenInfo = _getCkTokenInfo(tokenId);
        tokens := Trie.remove(tokens, keyt(tokenId), Text.equal).0;
        cyclesMonitor := CyclesMonitor.remove(cyclesMonitor, tokenInfo.ckLedgerId);
    };
    public shared(msg) func clearEvents(_clearFrom: BlockHeight, _clearTo: BlockHeight): async (){
        assert(_onlyOwner(msg.caller));
        assert(_clearTo >= _clearFrom);
        blockEvents := ICEvents.clearEvents<Event>(blockEvents, _clearFrom, _clearTo);
        firstBlockIndex := _clearTo + 1;
    };
    public shared(msg) func clearRpcLogs(_idFrom: RpcId, _idTo: RpcId) : async (){
        assert(_onlyOwner(msg.caller));
        assert(_idTo >= _idFrom);
        _clearRpcLogs(_idFrom, _idTo);
    };
    public shared(msg) func clearRpcRequests(_idFrom: RpcRequestId, _idTo: RpcRequestId) : async (){
        assert(_onlyOwner(msg.caller));
        assert(_idTo >= _idFrom);
        _clearRpcRequests(_idFrom, _idTo);
    };
    public shared(msg) func clearDepositTxns() : async (){
        assert(_onlyOwner(msg.caller));
        depositTxns := Trie.filter<TxHashId, (tx: DepositTxn, updatedTime: Timestamp)>(depositTxns, func (k: TxHashId, v: (tx: DepositTxn, updatedTime: Timestamp)): Bool{
            _now() <= v.1 + VALID_BLOCKS_FOR_CLAIMING_TXN * ckNetworkBlockSlot + 7 * 24 * 3600
        });
        pendingDepositTxns := Trie.filter<TxHashId, Minter.PendingDepositTxn>(pendingDepositTxns, func (k: TxHashId, v: Minter.PendingDepositTxn): Bool{
            _now() <= v.4 + VALID_BLOCKS_FOR_CLAIMING_TXN * ckNetworkBlockSlot + 7 * 24 * 3600
        });
    };
    public shared(msg) func clearCkTransactions() : async (){
        assert(_onlyOwner(msg.caller));
        transactions := Trie.filter<TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp)>(transactions, 
            func (k: TxIndex, v: (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp)): Bool{
                let res = (v.0.status != #Confirmed and v.0.status != #Failure) or _now() <= v.1 + VALID_BLOCKS_FOR_CLAIMING_TXN * ckNetworkBlockSlot + 7 * 24 * 3600;
                if (not(res) and not(_isRetrieving(k))){
                    retrievals := Trie.remove(retrievals, keyn(k), Nat.equal).0;
                };
                return res;
            }
        );
    };

    // Cycles monitor
    public shared(msg) func monitor_put(_canisterId: Principal): async (){
        assert(_onlyOwner(msg.caller));
        cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, _canisterId);
    };
    public shared(msg) func monitor_remove(_canisterId: Principal): async (){
        assert(_onlyOwner(msg.caller));
        cyclesMonitor := CyclesMonitor.remove(cyclesMonitor, _canisterId);
    };
    public query func monitor_canisters(): async [(Principal, Nat)]{
        return Iter.toArray(Trie.iter(cyclesMonitor));
    };
        
    /** Debug **/
    public shared(msg) func debug_get_rpc(_offset: Nat) : async (keeper: AccountId, rpcUrl: Text, size: Nat){
        assert(_onlyOwner(msg.caller));
        return _getRpcUrl(_offset);
    };
    public shared(msg) func debug_outcall(_rpcUrl: Text, _input: Text, _responseSize: Nat64) : async (status: Nat, body: Blob, json: Text){
        assert(_onlyOwner(msg.caller));
        return await* RpcCaller.call(_rpcUrl, _input, _responseSize, RPC_AGENT_CYCLES, ?{function = rpc_call_transform; context = Blob.fromArray([])});
    };
    public shared(msg) func debug_fetch_address(_account : Account) : async (pubkey:PubKey, ethAccount:EthAccount, address: EthAddress){
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        return await* _fetchAccountAddress([accountId]);
    };
    public shared(msg) func debug_get_address(_account : Account) : async (EthAddress, Nonce){
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        return await* _getEthAddress(accountId, true);
    };
    public shared(msg) func debug_fetch_nonce(_arg: {#latest; #pending}) : async Nonce{
        assert(_onlyOwner(msg.caller));
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccountId);
        let nonce = await* _fetchAccountNonce(mainAddress, _arg);
        return nonce;
    };
    public shared(msg) func debug_fetch_balance(_token: ?EthAddress, _address: EthAddress, _latest: Bool) : async Nat{
        assert(_onlyOwner(msg.caller));
        let tokenId = _toLower(Option.get(_token, eth_));
        return await* _fetchBalance(tokenId, _address, _latest);
    };
    public shared(msg) func debug_fetch_token_metadata(_token: EthAddress) : async {symbol: Text; decimals: Nat8 }{
        assert(_onlyOwner(msg.caller));
        return await* _fetchERC20Metadata(_token);
    };
    public shared(msg) func debug_fetch_txn(_txHash: TxHash): async (rpcSuccess: Bool, txn: ?Minter.TokenTxn, height: BlockHeight, confirmation: Status, txNonce: ?Nat, returns: ?[Text]){
        assert(_onlyOwner(msg.caller));
        return await* _fetchTxn(_txHash);
    };
    public shared(msg) func debug_fetch_receipt(_txHash: TxHash) : async (Bool, BlockHeight, Status, ?[Text]){
        assert(_onlyOwner(msg.caller));
        return await* _fetchTxReceipt(_txHash);
    };
    public shared(msg) func debug_get_tx(_txi: TxIndex) : async ?Minter.TxStatus{
        assert(_onlyOwner(msg.caller));
        return _getTx(_txi);
    };
    public shared(msg) func debug_new_tx(_type: {#Deposit; #DepositGas; #Withdraw}, _account: Account, _tokenId: ?EthAddress, _from: EthAddress, _to: EthAddress, _amount: Wei) : async TxIndex{
        assert(_onlyOwner(msg.caller));
        let tokenId = _toLower(Option.get(_tokenId, eth_));
        let gasFee = _getEthGas(tokenId);
        return _newTx(_type, _account: Account, tokenId, _from, _to, _amount, gasFee);
    };
    public shared(msg) func debug_local_getNonce(_txi: TxIndex) : async {txi: Nat; address: EthAddress; nonce: Nonce}{
        assert(_onlyOwner(msg.caller));
        return await* _local_getNonce(_txi, null);
    };
    public shared(msg) func debug_local_createTx(_txi: TxIndex) : async {txi: Nat; rawTx: [Nat8]; txHash: TxHash}{
        assert(_onlyOwner(msg.caller));
        return await* _local_createTx(_txi);
    };
    public shared(msg) func debug_local_signTx(_txi: TxIndex) : async ({txi: Nat; signature: [Nat8]; rawTx: [Nat8]; txHash: TxHash}){
        assert(_onlyOwner(msg.caller));
        let res = await* _local_signTx(_txi);
        return (res);
    };
    public shared(msg) func debug_local_sendTx(_txi: TxIndex) : async {txi: Nat; result: Result.Result<TxHash, Text>; rpcId: RpcId}{
        assert(_onlyOwner(msg.caller));
        let res = await* _local_sendTx(_txi);
        return (res);
    };
    public shared(msg) func debug_sync_tx(_txi: TxIndex) : async (){
        assert(_onlyOwner(msg.caller));
        await* _syncTxStatus(_txi, true);
    };
    public shared(msg) func debug_sign_and_recover_msg(_msg: Text) : async {address: Text; msgHash: Text; signature: Text; recovered: Text}{
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(msg.caller, null);
        let msgRaw = Blob.toArray(Text.encodeUtf8(_msg));
        let msgHash = ETHCrypto.sha3(msgRaw);
        let signature = await* _sign([accountId], msgHash);
        var address = "";
        let ecdsa_public_key = await ic.ecdsa_public_key({
            canister_id = null;
            derivation_path = [accountId];
            key_id = { curve = #secp256k1; name = KEY_NAME };
        });
        switch(ETHCrypto.pubToAddress(Blob.toArray(ecdsa_public_key.public_key))){
            case(#ok(v)){ address := v };
            case(_){};
        };
        var recoveredAddress = ""; 
        switch(ETHCrypto.recover(signature, msgHash, address, ck_chainId, ecContext)){
            case(#ok(addr)){ recoveredAddress := addr };
            case(#err(e)){ throw Error.reject(e); };
        };
        return {address = address; msgHash = ABI.toHex(msgHash); signature = ABI.toHex(signature); recovered = recoveredAddress};
    };
    public shared(msg) func debug_send_to(_principal: Principal, _from: EthAddress, _to: EthAddress, _amount: Wei): async TxIndex{
        assert(_onlyOwner(msg.caller));
        // testMainnet := true;
        let accountId = _accountId(_principal, null);
        let gasFee = _getEthGas(eth_);
        let txi = _newTx(#Deposit, {owner = _principal; subaccount = null }, eth_, _from, _to, _amount, gasFee);
        //ICTC:
        let saga = _getSaga();
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
        let toid : Nat = saga.create("debug_send_to", #Backward, ?txiBlob, null);
        let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#getNonce(txi, ?[toid])), [], 0, null, null);
        let comp1 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0, null, null);
        let _ttid1 = saga.push(toid, task1, ?comp1, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx(txi)), [], 0, null, null);
        let comp2 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#createTx_comp(txi)), [], 0, null, null);
        let _ttid2 = saga.push(toid, task2, ?comp2, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#signTx(txi)), [], 0, null, null);
        let comp3 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0, null, null);
        let _ttid3 = saga.push(toid, task3, ?comp3, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(txi)), [], 0, null, null);
        let comp4 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0, null, null);
        let _ttid4 = saga.push(toid, task4, ?comp4, null);
        let task5 = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#syncTx(txi, false)), [], 0, ?txTaskAttempts, ?_txTaskInterval());
        let comp5 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0, null, null);
        let _ttid5 = saga.push(toid, task5, ?comp5, null);
        saga.close(toid);
        _updateTxToids(txi, [toid]);
        await* _ictcSagaRun(toid, false);
        // testMainnet := false;
        return txi;
    };
    public shared(msg) func debug_verify_sign(_signer: EthAddress, _account : Account, _txHash: TxHash, _signature: [Nat8]) : async (Text, {r: [Nat8]; s: [Nat8]; v: Nat64}, EthAddress){
        assert(_onlyOwner(msg.caller));
        let message = _depositingMsg(_txHash, _account);
        let msgHash = ETHCrypto.sha3(message);
        var rsv = {r: [Nat8] = []; s: [Nat8] = []; v: Nat64 = 0};
        switch(ETHCrypto.convertSignature(_signature, msgHash, _signer, ck_chainId, ecContext)){
            case(#ok(rsv_)){ rsv := rsv_ };
            case(#err(e)){ throw Error.reject(e); };
        };
        var address = ""; 
        switch(ETHCrypto.recover(_signature, msgHash, _signer, ck_chainId, ecContext)){
            case(#ok(addr)){ address := addr };
            case(#err(e)){ throw Error.reject(e); };
        };
        return (ABI.toHex(message), rsv, address);
    };
    public shared(msg) func debug_sha3(_msg: Text): async Text{
        assert(_onlyOwner(msg.caller));
        let hex = ABI.toHex(ETHCrypto.sha3(Blob.toArray(Text.encodeUtf8(_msg))));
        // assert(hex == ABI.toHex(await utils.keccak256(Blob.toArray(Text.encodeUtf8(_msg)))));
        return hex;
    };
    public shared(msg) func debug_updateBalance(_aid: ?AccountId): async (){
        assert(_onlyOwner(msg.caller));
        await* _updateBalance(_aid);
    };
    public shared(msg) func debug_clearMethod2Txn(): async (){
        assert(_onlyOwner(msg.caller));
        await* _clearMethod2Txn();
    };
    public shared(msg) func debug_updateTokenEthRatio(): async (){
        assert(_onlyOwner(msg.caller));
        lastUpdateTokenPriceTime := 0;
        await* _updateTokenEthRatio();
    };
    public shared(msg) func debug_convertFees(): async (){
        assert(_onlyOwner(msg.caller));
        lastConvertFeesTime := 0;
        let temp = convertFeesIntervalSeconds;
        convertFeesIntervalSeconds := 0;
        await* _convertFees();
        convertFeesIntervalSeconds := temp;
    };
    public shared(msg) func debug_reconciliation(): async (){
        assert(_onlyOwner(msg.caller));
        await* _reconciliation();
    };
    public shared(msg) func debug_removeDepositingTxi(_accountId: AccountId, _txIndex: TxIndex): async (){
        assert(_onlyOwner(msg.caller));
        ignore _removeDepositingTxIndex(_accountId, _txIndex);
    };
    public shared(msg) func debug_removeRetrievingTxi(_txIndex: TxIndex): async (){
        assert(_onlyOwner(msg.caller));
        _removeRetrievingTxIndex(_txIndex);
    };
    public shared(msg) func debug_canister_status(_canisterId: Principal): async CyclesMonitor.canister_status {
        assert(_onlyOwner(msg.caller));
        return await* CyclesMonitor.get_canister_status(_canisterId);
    };
    public shared(msg) func debug_monitor(): async (){
        assert(_onlyOwner(msg.caller));
        for ((tokenId, tokenInfo) in Trie.iter(tokens)){
            if (app_debug){
                cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, tokenInfo.ckLedgerId);
            };
        };
        let monitor = await* CyclesMonitor.monitor(Principal.fromActor(this), cyclesMonitor, INIT_CKTOKEN_CYCLES / (if (app_debug) {2} else {1}), INIT_CKTOKEN_CYCLES * 50, 500000000);
        if (Trie.size(cyclesMonitor) == Trie.size(monitor)){
            cyclesMonitor := monitor;
        };
    };
    public shared(msg) func debug_fetchPairPrice(_pair: Principal) : async Float{
        assert(_onlyOwner(msg.caller));
        return await* _fetchPairPrice(_pair);
    };
    public shared(msg) func debug_updateTokenPrice(_tokenId: EthAddress) : async (){
        assert(_onlyOwner(msg.caller));
        return await* _updateTokenPrice(_tokenId);
    };
    public shared(msg) func debug_removePendingDepositTxn(_txHash: TxHash) : async (){
        assert(_onlyOwner(msg.caller));
        return _removePendingDepositTxn(_txHash);
    };

    /**
    * ICTC Transaction Explorer Interface
    * (Optional) Implement the following interface, which allows you to browse transaction records and execute compensation transactions through a UI interface.
    * https://cmqwp-uiaaa-aaaaj-aihzq-cai.raw.ic0.app/
    */
    // ICTC: management functions
    private stable var ictc_admins: [Principal] = [];
    private func _onlyIctcAdmin(_caller: Principal) : Bool { 
        return Option.isSome(Array.find(ictc_admins, func (t: Principal): Bool{ t == _caller }));
    }; 
    private func _onlyBlocking(_toid: Nat) : Bool{
        /// Saga
        switch(_getSaga().status(_toid)){
            case(?(status)){ return status == #Blocking }; //  or status == #Compensating
            case(_){ return false; };
        };
        /// 2PC
        // switch(_getTPC().status(_toid)){
        //     case(?(status)){ return status == #Blocking };
        //     case(_){ return false; };
        // };
    };
    public query func ictc_getAdmins() : async [Principal]{
        return ictc_admins;
    };
    public shared(msg) func ictc_addAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller)); // or _onlyIctcAdmin(msg.caller)
        if (Option.isNull(Array.find(ictc_admins, func (t: Principal): Bool{ t == _admin }))){
            ictc_admins := Tools.arrayAppend(ictc_admins, [_admin]);
        };
    };
    public shared(msg) func ictc_removeAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller)); // or _onlyIctcAdmin(msg.caller)
        ictc_admins := Array.filter(ictc_admins, func (t: Principal): Bool{ t != _admin });
    };

    // SagaTM Scan
    public query func ictc_TM() : async Text{
        return "Saga";
    };
    /// Saga
    public query func ictc_getTOCount() : async Nat{
        return _getSaga().count();
    };
    public query func ictc_getTO(_toid: SagaTM.Toid) : async ?SagaTM.Order<CustomCallType>{
        return _getSaga().getOrder(_toid);
    };
    public query func ictc_getTOs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Toid, SagaTM.Order<CustomCallType>)]; totalPage: Nat; total: Nat}{
        return _getSaga().getOrders(_page, _size);
    };
    public query func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order<CustomCallType>)]{
        return _getSaga().getAliveOrders();
    };
    public query func ictc_getTT(_ttid: SagaTM.Ttid) : async ?SagaTM.TaskEvent<CustomCallType>{
        return _getSaga().getActuator().getTaskEvent(_ttid);
    };
    public query func ictc_getTTByTO(_toid: SagaTM.Toid) : async [SagaTM.TaskEvent<CustomCallType>]{
        return _getSaga().getTaskEvents(_toid);
    };
    public query func ictc_getTTs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Ttid, SagaTM.TaskEvent<CustomCallType>)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getTaskEvents(_page, _size);
    };
    public query func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task<CustomCallType>)]{
        let pool = _getSaga().getActuator().getTaskPool();
        let arr = Array.map<(SagaTM.Ttid, SagaTM.Task<CustomCallType>), (SagaTM.Ttid, SagaTM.Task<CustomCallType>)>(pool, 
        func (item:(SagaTM.Ttid, SagaTM.Task<CustomCallType>)): (SagaTM.Ttid, SagaTM.Task<CustomCallType>){
            (item.0, item.1);
        });
        return arr;
    };
    public query func ictc_getTTErrors(_page: Nat, _size: Nat) : async {data: [(Nat, SagaTM.ErrorLog)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getErrorLogs(_page, _size);
    };
    public query func ictc_getCalleeStatus(_callee: Principal) : async ?SagaTM.CalleeStatus{
        return _getSaga().getActuator().calleeStatus(_callee);
    };
    /// Transaction Governance
    public shared(msg) func ictc_clearLog(_expiration: ?Int, _delForced: Bool) : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().clear(_expiration, _delForced);
    };
    public shared(msg) func ictc_clearTTPool() : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().getActuator().clearTasks();
    };
    public shared(msg) func ictc_blockTO(_toid: SagaTM.Toid) : async ?SagaTM.Toid{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(not(_onlyBlocking(_toid)));
        let saga = _getSaga();
        return saga.block(_toid);
    };
    // public shared(msg) func ictc_removeTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{ // Warning: Execute this method with caution
    //     assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
    //     assert(_onlyBlocking(_toid));
    //     let saga = _getSaga();
    //     saga.open(_toid);
    //     let ttid = saga.remove(_toid, _ttid);
    //     saga.close(_toid);
    //     return ttid;
    // };
    public shared(msg) func ictc_appendTT(_businessId: ?Blob, _toid: SagaTM.Toid, _forTtid: ?SagaTM.Ttid, _callee: Principal, _callType: SagaTM.CallType<CustomCallType>, _preTtids: [SagaTM.Ttid]) : async SagaTM.Ttid{
        // Governance or manual compensation (operation allowed only when a transaction order is in blocking status).
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.open(_toid);
        let taskRequest = _buildTask(_businessId, _callee, _callType, _preTtids, 0, null, null);
        //let ttid = saga.append(_toid, taskRequest, null, null);
        let ttid = saga.appendComp(_toid, Option.get(_forTtid, 0), taskRequest, null);
        return ttid;
    };
    /// Try the task again
    public shared(msg) func ictc_redoTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        let ttid = saga.redo(_toid, _ttid);
        await* _ictcSagaRun(_toid, true);
        return ttid;
    };
    /// set status of pending task
    public shared(msg) func ictc_doneTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid, _toCallback: Bool) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        try{
            let ttid = await* saga.taskDone(_toid, _ttid, _toCallback);
            return ttid;
        }catch(e){
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// set status of pending order
    public shared(msg) func ictc_doneTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _toCallback: Bool) : async Bool{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            let res = await* saga.done(_toid, _status, _toCallback);
            return res;
        }catch(e){
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// Complete blocking order
    public shared(msg) func ictc_completeTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus) : async Bool{
        // After governance or manual compensations, this method needs to be called to complete the transaction order.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.close(_toid);
        await* _ictcSagaRun(_toid, true);
        try{
            let r = await* _getSaga().complete(_toid, _status);
            return r;
        }catch(e){
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTO(_toid: SagaTM.Toid) : async ?SagaTM.OrderStatus{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            // countAsyncMessage += 2;
            let r = await saga.run(_toid);
            // countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            // countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTT() : async Bool{ 
        // There is no need to call it normally, but can be called if you want to execute tasks in time when a TO is in the Doing state.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller) or _notPaused());
        // if (not(_checkAsyncMessageLimit())){
        //     throw Error.reject("405: IC network is busy, please try again later."); 
        // };
        // _sessionPush(msg.caller);
        let saga = _getSaga();
        if (_onlyOwner(msg.caller)){
            await* _ictcSagaRun(0, true);
        } else if (Time.now() > lastSagaRunningTime + ICTC_RUN_INTERVAL*ns_){ 
            await* _ictcSagaRun(0, false);
        };
        return true;
    };
    /**
    * End: ICTC Transaction Explorer Interface
    */

    /* ===========================
      DRC207 section
    ============================== */
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };
    /// canister_status
    // public shared(msg) func canister_status() : async DRC207.canister_status {
    //     // _sessionPush(msg.caller);
    //     // if (_tps(15, null).1 > setting.MAX_TPS*5 or _tps(15, ?msg.caller).0 > 2){ 
    //     //     assert(false); 
    //     // };
    //     let ic : DRC207.IC = actor("aaaaa-aa");
    //     await ic.canister_status({ canister_id = Principal.fromActor(this) });
    // };
    // receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let _accepted = Cycles.accept<system>(amout);
    };
    /// timer tick
    // public shared(msg) func timer_tick(): async (){
    //     //
    // };

    private func timerLoop() : async (){
        if (_now() > lastMonitorTime + 24 * 3600){
            try{ 
                let monitor = await* CyclesMonitor.monitor(Principal.fromActor(this), cyclesMonitor, INIT_CKTOKEN_CYCLES / (if (app_debug) {2} else {1}), INIT_CKTOKEN_CYCLES * 50, 0);
                if (Trie.size(cyclesMonitor) == Trie.size(monitor)){
                    cyclesMonitor := monitor;
                };
                lastMonitorTime := _now();
             }catch(e){};
        };
        if (_notPaused()){
            try{ await* _updateTokenEthRatio() }catch(e){};
            try{ await* _convertFees() }catch(e){}; /*config*/
            try{ await* _reconciliation() }catch(e){}; /*config*/
            if (rpcId > firstRpcId + 3000){
                _clearRpcLogs(firstRpcId, Nat.sub(rpcId, 3000)); 
            }; 
            if (rpcRequestId > firstRpcRequestId + 1500){
                _clearRpcRequests(firstRpcRequestId, Nat.sub(rpcRequestId, 1500));
            };
        };
    };
    private func timerLoop2() : async (){
        if (_notPaused()){
            if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
                try{
                    ck_gasPrice := await* _fetchGasPrice();
                    ck_ethBlockNumber := (await* _fetchBlockNumber(), _now());
                    lastGetGasPriceTime := _now();
                }catch(e){};
            };
            try{ await* _syncTxs() }catch(e){};
            try{ await* _clearMethod2Txn() }catch(e){};
            try{ await* _coverPendingTxs() }catch(e){};
            try{ await* _ictcSagaRun(0, false) }catch(e){};
            let (keeper, url, total) = _getRpcUrl(0);
            if (total < minRpcConfirmations){
                paused := true;
                ignore _putEvent(#suspend({message = ?"Insufficient number of available RPC nodes."}), ?_accountId(Principal.fromActor(this), null));
            };
        };
    };
    private var timerId: Nat = 0;
    private var timerId2: Nat = 0;
    public shared(msg) func timerStart(_intervalSeconds1: Nat, _intervalSeconds2: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(timerId2);
        timerId := Timer.recurringTimer<system>(#seconds(_intervalSeconds1), timerLoop);
        timerId2 := Timer.recurringTimer<system>(#seconds(_intervalSeconds2), timerLoop2);
    };
    public shared(msg) func timerStop(): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(timerId2);
    };
    
    /* ===========================
      Init Event
    ============================== */
    private stable var initialized: Bool = false;
    if (not(initialized)){
        ignore _putEvent(#init({initArgs = initArgs}), ?_accountId(owner, null));
        initialized := true;
    };

    /* ===========================
      Upgrade section
    ============================== */
    private stable var __sagaDataNew: ?SagaTM.Data<CustomCallType> = null;
    system func preupgrade() {
        let data = _getSaga().getData();
        __sagaDataNew := ?data;
        // assert(List.size(data.actuator.tasks.0) == 0 and List.size(data.actuator.tasks.1) == 0);
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(timerId2);
    };
    system func postupgrade() {
        switch(__sagaDataNew){
            case(?(data)){
                _getSaga().setData(data);
                __sagaDataNew := null;
            };
            case(_){};
        };
        timerId := Timer.recurringTimer<system>(#seconds(if (app_debug) {3600*2} else {1800}), timerLoop);
        timerId2 := Timer.recurringTimer<system>(#seconds(if (app_debug) {300} else {180}), timerLoop2);
    };

    /* ===========================
      Backup / Recovery section
    ============================== */
    /// ## Backup and Recovery
    /// The backup and recovery functions are not normally used, but are used when canister cannot be upgraded and needs to be reinstalled:
    /// - call backup() method to back up the data.
    /// - reinstall cansiter.
    /// - call recovery() to restore the data.
    /// Caution:
    /// - If the data in this canister has a dependency on canister-id, it must be reinstalled in the same canister and cannot be migrated to a new canister.
    /// - Normal access needs to be stopped during backup and recovery, otherwise the data may be contaminated.
    /// - Backup and recovery operations have been categorized by variables, and each operation can only target one category of data, so multiple operations are required to complete the backup and recovery of all data.
    /// - The backup and recovery operations are not paged for single-variable datasets. If you encounter a failure due to large data size, please try the following:
    ///     - Calling canister's cleanup function or configuration will delete stale data for some variables.
    ///     - Backup and recovery of non-essential data can be ignored.
    ///     - Query the necessary data through other query functions, and then call recovery() to restore the data.
    ///     - Abandon this solution and seek other data recovery solutions.
    
    type Order<CustomCallType> = SagaTM.Order<CustomCallType>;
    type Task<CustomCallType> = SagaTM.Task<CustomCallType>;
    type SagaData<CustomCallType> = Backup.SagaData<CustomCallType>;
    type BackupRequest = Backup.BackupRequest;
    type BackupResponse<CustomCallType> = Backup.BackupResponse<CustomCallType>;

    /// Backs up data of the specified `BackupRequest` classification, and the result is wrapped using the `BackupResponse` type.
    public shared(msg) func backup(_request: BackupRequest) : async BackupResponse<CustomCallType>{
        assert(_onlyOwner(msg.caller));
        switch(_request){
            case(#otherData){
                return #otherData({
                    countMinting = countMinting;
                    totalMinting = totalMinting;
                    countRetrieval = countRetrieval;
                    totalRetrieval = totalRetrieval;
                    quoteToken = quoteToken;
                    txIndex = txIndex;
                    ck_chainId = ck_chainId;
                    ck_ethBlockNumber = ck_ethBlockNumber;
                    ck_gasPrice = ck_gasPrice;
                    rpcId = rpcId;
                    firstRpcId = firstRpcId;
                    rpcRequestId = rpcRequestId;
                    firstRpcRequestId = firstRpcRequestId;
                    blockIndex = blockIndex;
                    firstBlockIndex = firstBlockIndex;
                    ictc_admins = ictc_admins;
                });
            };
            case(#icrc1WasmHistory){
                let icrc1Wasm: [(wasm: [Nat8], version: Text)] = (if (icrc1WasmHistory.size() > 0){ [icrc1WasmHistory[0]] }else{ [] });
                return #icrc1WasmHistory(icrc1Wasm);
            };
            case(#accounts){
                return #accounts(Trie.toArray<AccountId, (EthAddress, Nonce), (AccountId, (EthAddress, Nonce))>(accounts, 
                    func (k: AccountId, v: (EthAddress, Nonce)): (AccountId, (EthAddress, Nonce)){
                        return (k, v);
                    }));
            };
            case(#tokens){
                return #tokens(Trie.toArray<EthAddress, Minter.TokenInfo, (EthAddress, Minter.TokenInfo)>(tokens, 
                    func (k: EthAddress, v: Minter.TokenInfo): (EthAddress, Minter.TokenInfo){
                        return (k, v);
                    }));
            };
            case(#deposits){
                return #deposits(Trie.toArray<AccountId, TxIndex, (AccountId, TxIndex)>(deposits, 
                    func (k: AccountId, v: TxIndex): (AccountId, TxIndex){
                        return (k, v);
                    }));
            };
            case(#balances){
                return #balances(Trie.toArray<AccountId, Trie.Trie<Minter.EthTokenId, (Account, Wei)>, (AccountId, [(Minter.EthTokenId, (Account, Wei))])>(balances, 
                    func (k: AccountId, v: Trie.Trie<Minter.EthTokenId, (Account, Wei)>): (AccountId, [(Minter.EthTokenId, (Account, Wei))]){
                        let values: [(Minter.EthTokenId, (Account, Wei))] = Trie.toArray<Minter.EthTokenId, (Account, Wei), (Minter.EthTokenId, (Account, Wei))>(v, 
                        func (k2: Minter.EthTokenId, v2: (Account, Wei)): (Minter.EthTokenId, (Account, Wei)){
                            return (k2, v2);
                        });
                        return (k, values);
                    }));
            };
            case(#feeBalances){
                return #feeBalances(Trie.toArray<Minter.EthTokenId, Wei, (Minter.EthTokenId, Wei)>(feeBalances, 
                    func (k: Minter.EthTokenId, v: Wei): (Minter.EthTokenId, Wei){
                        return (k, v);
                    }));
            };
            case(#retrievals){
                return #retrievals(Trie.toArray<TxIndex, Minter.RetrieveStatus, (TxIndex, Minter.RetrieveStatus)>(retrievals, 
                    func (k: TxIndex, v: Minter.RetrieveStatus): (TxIndex, Minter.RetrieveStatus){
                        return (k, v);
                    }));
            };
            case(#withdrawals){
                return #withdrawals(Trie.toArray<AccountId, List.List<TxIndex>, (AccountId, [TxIndex])>(withdrawals, 
                    func (k: AccountId, v: List.List<TxIndex>): (AccountId, [TxIndex]){
                        return (k, List.toArray(v));
                    }));
            };
            case(#pendingRetrievals){
                return #pendingRetrievals(List.toArray(pendingRetrievals));
            };
            case(#transactions){
                return #transactions(Trie.toArray<TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp), (TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp))>(transactions, 
                    func (k: TxIndex, v: (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp)): (TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp)){
                        return (k, v);
                    }));
            };
            case(#depositTxns){
                return #depositTxns(Trie.toArray<TxHashId, (tx: Minter.DepositTxn, updatedTime: Timestamp), (TxHashId, (tx: Minter.DepositTxn, updatedTime: Timestamp))>(depositTxns, 
                    func (k: TxHashId, v: (tx: Minter.DepositTxn, updatedTime: Timestamp)): (TxHashId, (tx: Minter.DepositTxn, updatedTime: Timestamp)){
                        return (k, v);
                    }));
            };
            case(#pendingDepositTxns){
                return #pendingDepositTxns(Trie.toArray<TxHashId, Minter.PendingDepositTxn, (TxHashId, Minter.PendingDepositTxn)>(pendingDepositTxns, 
                    func (k: TxHashId, v: Minter.PendingDepositTxn): (TxHashId, Minter.PendingDepositTxn){
                        return (k, v);
                    }));
            };
            case(#ck_keepers){
                return #ck_keepers(Trie.toArray<AccountId, Minter.Keeper, (AccountId, Minter.Keeper)>(ck_keepers, 
                    func (k: AccountId, v: Minter.Keeper): (AccountId, Minter.Keeper){
                        return (k, v);
                    }));
            };
            case(#ck_rpcProviders){
                return #ck_rpcProviders(Trie.toArray<AccountId, Minter.RpcProvider, (AccountId, Minter.RpcProvider)>(ck_rpcProviders, 
                    func (k: AccountId, v: Minter.RpcProvider): (AccountId, Minter.RpcProvider){
                        return (k, v);
                    }));
            };
            case(#ck_rpcLogs){
                return #ck_rpcLogs(Trie.toArray<Minter.RpcId, Minter.RpcLog, (Minter.RpcId, Minter.RpcLog)>(ck_rpcLogs, 
                    func (k: Minter.RpcId, v: Minter.RpcLog): (Minter.RpcId, Minter.RpcLog){
                        return (k, v);
                    }));
            };
            case(#ck_rpcRequests){
                return #ck_rpcRequests(Trie.toArray<Minter.RpcRequestId, Minter.RpcRequestConsensus, (Minter.RpcRequestId, Minter.RpcRequestConsensus)>(ck_rpcRequests, 
                    func (k: Minter.RpcRequestId, v: Minter.RpcRequestConsensus): (Minter.RpcRequestId, Minter.RpcRequestConsensus){
                        return (k, v);
                    }));
            };
            case(#kyt_accountAddresses){
                return #kyt_accountAddresses(Trie.toArray<AccountId, [KYT.ChainAccount], (AccountId, [KYT.ChainAccount])>(kyt_accountAddresses, 
                    func (k: AccountId, v: [KYT.ChainAccount]): (AccountId, [KYT.ChainAccount]){
                        return (k, v);
                    }));
            };
            case(#kyt_addressAccounts){
                return #kyt_addressAccounts(Trie.toArray<Address, [KYT.ICAccount], (Address, [KYT.ICAccount])>(kyt_addressAccounts, 
                    func (k: Address, v: [KYT.ICAccount]): (Address, [KYT.ICAccount]){
                        return (k, v);
                    }));
            };
            case(#kyt_txAccounts){
                return #kyt_txAccounts(Trie.toArray<KYT.HashId, [(KYT.ChainAccount, KYT.ICAccount)], (KYT.HashId, [(KYT.ChainAccount, KYT.ICAccount)])>(kyt_txAccounts, 
                    func (k: KYT.HashId, v: [(KYT.ChainAccount, KYT.ICAccount)]): (KYT.HashId, [(KYT.ChainAccount, KYT.ICAccount)]){
                        return (k, v);
                    }));
            };
            case(#blockEvents){
                return #blockEvents(Trie.toArray<Minter.BlockHeight, (Minter.Event, Timestamp), (Minter.BlockHeight, (Minter.Event, Timestamp))>(blockEvents, 
                    func (k: Minter.BlockHeight, v: (Minter.Event, Timestamp)): (Minter.BlockHeight, (Minter.Event, Timestamp)){
                        return (k, v);
                    }));
            };
            case(#accountEvents){
                return #accountEvents(Trie.toArray<AccountId, List.List<Minter.BlockHeight>, (AccountId, [Minter.BlockHeight])>(accountEvents, 
                    func (k: AccountId, v: List.List<Minter.BlockHeight>): (AccountId, [Minter.BlockHeight]){
                        return (k, List.toArray(v));
                    }));
            };
            case(#cyclesMonitor){
                return #cyclesMonitor(Trie.toArray<Principal, Nat, (Principal, Nat)>(cyclesMonitor, 
                    func (k: Principal, v: Nat): (Principal, Nat){
                        return (k, v);
                    }));
            };
            case(#sagaData(mode)){
                var data = _getSaga().getDataBase();
                if (mode == #All){
                    data := _getSaga().getData();
                };
                return #sagaData({
                    autoClearTimeout = data.autoClearTimeout; 
                    index = data.index; 
                    firstIndex = data.firstIndex; 
                    orders = data.orders; 
                    aliveOrders = List.toArray(data.aliveOrders); 
                    taskEvents = data.taskEvents; 
                    actuator = {
                        tasks = (List.toArray(data.actuator.tasks.0), List.toArray(data.actuator.tasks.1)); 
                        taskLogs = data.actuator.taskLogs; 
                        errorLogs = data.actuator.errorLogs; 
                        callees = data.actuator.callees; 
                        index = data.actuator.index; 
                        firstIndex = data.actuator.firstIndex; 
                        errIndex = data.actuator.errIndex; 
                        firstErrIndex = data.actuator.firstErrIndex; 
                    }; 
                });
            };
        };
    };
    
    /// Restore `BackupResponse` data to the canister's global variable.
    public shared(msg) func recovery(_request: BackupResponse<CustomCallType>) : async Bool{
        assert(_onlyOwner(msg.caller));
        switch(_request){
            case(#otherData(data)){
                countMinting := data.countMinting;
                totalMinting := data.totalMinting;
                countRetrieval := data.countRetrieval;
                totalRetrieval := data.totalRetrieval;
                quoteToken := data.quoteToken;
                txIndex := data.txIndex;
                ck_chainId := data.ck_chainId;
                ck_ethBlockNumber := data.ck_ethBlockNumber;
                ck_gasPrice := data.ck_gasPrice;
                rpcId := data.rpcId;
                firstRpcId := data.firstRpcId;
                rpcRequestId := data.rpcRequestId;
                firstRpcRequestId := data.firstRpcRequestId;
                blockIndex := data.blockIndex;
                firstBlockIndex := data.firstBlockIndex;
                ictc_admins := data.ictc_admins;
            };
            case(#icrc1WasmHistory(data)){
                icrc1WasmHistory := data;
            };
            case(#accounts(data)){
                for ((k, v) in data.vals()){
                    accounts := Trie.put(accounts, keyb(k), Blob.equal, v).0;
                };
            };
            case(#tokens(data)){
                for ((k, v) in data.vals()){
                    tokens := Trie.put(tokens, keyt(k), Text.equal, v).0;
                };
            };
            case(#deposits(data)){
                for ((k, v) in data.vals()){
                    deposits := Trie.put(deposits, keyb(k), Blob.equal, v).0;
                };
            };
            case(#balances(data)){
                for ((k, v) in data.vals()){
                    var temp: Trie.Trie<Minter.EthTokenId, (Account, Wei)> = Trie.empty();
                    for ((k2, v2) in v.vals()){
                        temp := Trie.put(temp, keyb(k2), Blob.equal, v2).0;
                    };
                    balances := Trie.put(balances, keyb(k), Blob.equal, temp).0;
                };
            };
            case(#feeBalances(data)){
                for ((k, v) in data.vals()){
                    feeBalances := Trie.put(feeBalances, keyb(k), Blob.equal, v).0;
                };
            };
            case(#retrievals(data)){
                for ((k, v) in data.vals()){
                    retrievals := Trie.put(retrievals, keyn(k), Nat.equal, v).0;
                };
            };
            case(#withdrawals(data)){
                for ((k, v) in data.vals()){
                    withdrawals := Trie.put(withdrawals, keyb(k), Blob.equal, List.fromArray(v)).0;
                };
            };
            case(#pendingRetrievals(data)){
                pendingRetrievals := List.fromArray(data);
            };
            case(#transactions(data)){
                for ((k, v) in data.vals()){
                    transactions := Trie.put(transactions, keyn(k), Nat.equal, v).0;
                };
            };
            case(#depositTxns(data)){
                for ((k, v) in data.vals()){
                    depositTxns := Trie.put(depositTxns, keyb(k), Blob.equal, v).0;
                };
            };
            case(#pendingDepositTxns(data)){
                for ((k, v) in data.vals()){
                    pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(k), Blob.equal, v).0;
                };
            };
            case(#ck_keepers(data)){
                for ((k, v) in data.vals()){
                    ck_keepers := Trie.put(ck_keepers, keyb(k), Blob.equal, v).0;
                };
            };
            case(#ck_rpcProviders(data)){
                for ((k, v) in data.vals()){
                    ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(k), Blob.equal, v).0;
                };
            };
            case(#ck_rpcLogs(data)){
                for ((k, v) in data.vals()){
                    ck_rpcLogs := Trie.put(ck_rpcLogs, keyn(k), Nat.equal, v).0;
                };
            };
            case(#ck_rpcRequests(data)){
                for ((k, v) in data.vals()){
                    ck_rpcRequests := Trie.put(ck_rpcRequests, keyn(k), Nat.equal, v).0;
                };
            };
            case(#kyt_accountAddresses(data)){
                for ((k, v) in data.vals()){
                    kyt_accountAddresses := Trie.put(kyt_accountAddresses, keyb(k), Blob.equal, v).0;
                };
            };
            case(#kyt_addressAccounts(data)){
                for ((k, v) in data.vals()){
                    kyt_addressAccounts := Trie.put(kyt_addressAccounts, keyt(k), Text.equal, v).0;
                };
            };
            case(#kyt_txAccounts(data)){
                for ((k, v) in data.vals()){
                    kyt_txAccounts := Trie.put(kyt_txAccounts, keyb(k), Blob.equal, v).0;
                };
            };
            case(#blockEvents(data)){
                for ((k, v) in data.vals()){
                    blockEvents := Trie.put(blockEvents, keyn(k), Nat.equal, v).0;
                };
            };
            case(#accountEvents(data)){
                for ((k, v) in data.vals()){
                    accountEvents := Trie.put(accountEvents, keyb(k), Blob.equal, List.fromArray(v)).0;
                };
            };
            case(#cyclesMonitor(data)){
                for ((k, v) in data.vals()){
                    cyclesMonitor := Trie.put(cyclesMonitor, keyp(k), Principal.equal, v).0;
                };
            };
            case(#sagaData(data)){
                _getSaga().setData({
                    autoClearTimeout = data.autoClearTimeout; 
                    index = data.index; 
                    firstIndex = data.firstIndex; 
                    orders = data.orders; 
                    aliveOrders = List.fromArray(data.aliveOrders); 
                    taskEvents = data.taskEvents; 
                    actuator = {
                        tasks = (List.fromArray(data.actuator.tasks.0), List.fromArray(data.actuator.tasks.1)); 
                        taskLogs = data.actuator.taskLogs; 
                        errorLogs = data.actuator.errorLogs; 
                        callees = data.actuator.callees; 
                        index = data.actuator.index; 
                        firstIndex = data.actuator.firstIndex; 
                        errIndex = data.actuator.errIndex; 
                        firstErrIndex = data.actuator.firstErrIndex; 
                    }; 
                });
            };
        };
        return true;
    };

};