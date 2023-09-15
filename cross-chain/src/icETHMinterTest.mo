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
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Int32 "mo:base/Int32";
import Int64 "mo:base/Int64";
import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Deque "mo:base/Deque";
import Order "mo:base/Order";
import Cycles "mo:base/ExperimentalCycles";
import ICRC1 "./lib/icl/ICRC1";
import DRC20 "./lib/icl/DRC20";
import ICTokens "./lib/icl/ICTokens";
import Binary "./lib/icl/Binary";
import Hex "./lib/icl/Hex";
import Tools "./lib/icl/Tools";
import SagaTM "./ICTC/SagaTM";
import DRC207 "./lib/icl/DRC207";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Result "mo:base/Result";
import ICECDSA "lib/ICECDSA";
import Minter "lib/MinterTypes";
import ETHUtils "lib/ETHUtils";
// import ETHRPC "lib/ETHRPC";
import ETHCrypto "lib/ETHCrypto";
import ABI "lib/ABI";
import JSON "lib/JSON";
import Timer "mo:base/Timer";
import IC "lib/IC";
import ICEvents "lib/ICEvents";
import EIP712 "lib/EIP712";
import ICDex "lib/icl/ICDexTypes";
import KYT "lib/KYT";
import CyclesMonitor "lib/CyclesMonitor";
import RpcCaller "lib/RpcCaller";

// Rules:
//      When depositing ETH, each account is processed in its own single thread.
// InitArgs = {
//     min_confirmations : ?Nat
//     rpc_confirmations: Nat;
//     utils_canister_id: Principal;
//     deposit_method: Nat8;
//   };
// Deploy:
// 1. Deploy minter canister 
// 2. setKeeper() and keeper_setRpc()
// 3. sync() and setPause(false)
// 4. setCkTokenWasm() 
// 5. launchToken() 
// 6. setTokenDexPair() 
// Production confirmations: 65 - 96
// "Ethereum", "ETH", 18, 12, record{min_confirmations=opt 15; rpc_confirmations = 2; utils_canister_id = principal "s6moc-4aaaa-aaaak-aelma-cai"; deposit_method=3}
shared(installMsg) actor class icETHMinter(initNetworkName: Text, initSymbol: Text, initDecimals: Nat8, initBlockSlot: Nat, initArgs: Minter.InitArgs) = this {
    assert(Option.get(initArgs.min_confirmations, 0) >= 10); /*config*/

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

    let KEY_NAME : Text = "key_1";
    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;
    let RPC_AGENT_CYCLES : Cycles = 200_000_000;
    let INIT_CKTOKEN_CYCLES: Cycles = 1000000000000; // 1T
    let ICTC_RUN_INTERVAL : Nat = 10;
    let MIN_VISIT_INTERVAL : Nat = 6; //seconds
    // let GAS_PER_BYTE : Nat = 68; // gas
    let MAX_PENDING_RETRIEVALS : Nat = 50; /*config*/
    let VALID_BLOCKS_FOR_CLAIMING_TXN: Nat = 648000; /*config*/
    
    private var app_debug : Bool = true; /*config*/
    private let version_: Text = "0.8.18"; /*config*/
    private let ns_: Nat = 1000000000;
    private let gwei_: Nat = 1000000000;
    private stable var minConfirmations : Nat = Option.get(initArgs.min_confirmations, 15);
    private stable var minRpcConfirmations : Nat = initArgs.rpc_confirmations;
    private stable var paused: Bool = true;
    private stable var ckNetworkName: Text = initNetworkName;
    private stable var ckNetworkSymbol: Text = initSymbol;
    private stable var ckNetworkDecimals: Nat8 = initDecimals;
    private stable var ckNetworkBlockSlot: Nat = initBlockSlot;
    private stable var owner: Principal = installMsg.caller;
    private stable var depositMethod: Nat8 = initArgs.deposit_method;
    // private stable var rpc_: Principal = initArgs.rpc_canister_id; //3ondx-siaaa-aaaam-abf3q-cai
    private stable var utils_: Principal = initArgs.utils_canister_id; 
    private stable var ic_: Principal = Principal.fromText("aaaaa-aa"); 
    private let eth_: Text = "0x0000000000000000000000000000000000000000";
    private let sa_zero : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]; // Main account
    private let sa_one : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]; // Fees account
    private let sa_two : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2]; // Fee Swap
    private let ic : ICECDSA.Self = actor(Principal.toText(ic_));
    // private let rpc : ETHRPC.Self = actor(Principal.toText(rpc_));
    private let utils : ETHUtils.Self = actor(Principal.toText(utils_));
    private var blackhole_: Text = "7hdtw-jqaaa-aaaak-aaccq-cai";
    private stable var icrc1WasmHistory: [(wasm: [Nat8], version: Text)] = [];

    private stable var countMinting: Wei = 0;
    private stable var totalMinting: Wei = 0; // ETH
    private stable var countRetrieval: Wei = 0;
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
    private stable var transactions = Trie.empty<TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp)>(); // Persistent storage
    private stable var depositTxns = Trie.empty<TxHashId, (tx: DepositTxn, updatedTime: Timestamp)>();    // Method 2: Persistent storage
    private stable var pendingDepositTxns = Trie.empty<TxHashId, Minter.PendingDepositTxn>();    // Method 2: pending temp
    private stable var lastUpdateTxsTime: Timestamp = 0;
    private stable var lastUpdateMode2TxnTime: Timestamp = 0;
    private stable var lastGetGasPriceTime: Timestamp = 0;
    private var getGasPriceIntervalSeconds: Timestamp = 10 * 60;/*config*/
    private stable var lastUpdateTokenPriceTime: Timestamp = 0;
    private var getTokenPriceIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {4 * 3600};/*config*/
    private stable var lastConvertFeesTime: Timestamp = 0;
    private var convertFeesIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {8 * 3600};/*config*/
    private stable var lastHealthinessSlotTime: Timestamp = 0;
    private var healthinessIntervalSeconds: Timestamp = if (app_debug) {2 * 3600} else {7 * 24 * 3600};/*config*/
    private stable var countRejections: Nat = 0;
    private stable var lastExecutionDuration: Int = 0;
    private stable var maxExecutionDuration: Int = 0;
    private stable var lastSagaRunningTime : Time.Time = 0;
    private stable var countAsyncMessage : Nat = 0;
    private stable var countICTCError: Nat = 0;

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

    // KYT (TODO)
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
        let length = Trie.size(_trie);
        if (_page < 1 or _size < 1){
            return {data = []; totalPage = 0; total = length; };
        };
        let offset = Nat.sub(_page, 1) * _size;
        var totalPage: Nat = length / _size;
        if (totalPage * _size < length) { totalPage += 1; };
        if (offset >= length){
            return {data = []; totalPage = totalPage; total = length; };
        };
        let end: Nat = offset + Nat.sub(_size, 1);
        var i: Nat = 0;
        var res: [(K, V)] = [];
        for ((k,v) in Trie.iter<K, V>(_trie)){
            if (i >= offset and i <= end){
                res := Tools.arrayAppend(res, [(k,v)]);
            };
            i += 1;
        };
        return {data = res; totalPage = totalPage; total = length; };
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
                        let (mainAddress, mainNonce) = _getEthAddressQuery(accountId);
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
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Building){
                    var chainId_ = ck_chainId;
                    // if (testMainnet){
                    //     chainId_ := 1;
                    // };
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    let isERC20 = tx.tokenId != eth_;
                    var txObj: Transaction = #EIP1559({
                        to = Option.get(ABI.fromHex(tx.to), []);
                        value = ABI.natABIEncode(tx.amount);
                        max_priority_fee_per_gas = ABI.natABIEncode(Nat.max(tx.fee.gasPrice / 10, 100000000)); 
                        data = [];
                        sign = null;
                        max_fee_per_gas = ABI.natABIEncode(tx.fee.gasPrice);
                        chain_id = Nat64.fromNat(chainId_);
                        nonce = ABI.natABIEncode(Option.get(tx.nonce, 0));
                        gas_limit = ABI.natABIEncode(tx.fee.gasLimit);
                        access_list = [];
                    });
                    if (isERC20){
                        txObj := #EIP1559({
                            to = Option.get(ABI.fromHex(tx.tokenId), []);
                            value = ABI.natABIEncode(0);
                            max_priority_fee_per_gas = ABI.natABIEncode(Nat.max(tx.fee.gasPrice / 10, 100000000)); 
                            data = ABI.encodeErc20Transfer(tx.to, tx.amount);
                            sign = null;
                            max_fee_per_gas = ABI.natABIEncode(tx.fee.gasPrice);
                            chain_id = Nat64.fromNat(chainId_);
                            nonce = ABI.natABIEncode(Option.get(tx.nonce, 0));
                            gas_limit = ABI.natABIEncode(tx.fee.gasLimit);
                            access_list = [];
                        });
                    };
                    try{
                        // countAsyncMessage += 1;
                        let rawTx = ETHCrypto.rlpEncode(txObj); 
                        let txHash = ETHCrypto.sha3(rawTx);
                        // switch(await utils.create_transaction(txObj)){
                        //     case(#Ok(rawTx, txHash)){
                                // countAsyncMessage -= Nat.min(1, countAsyncMessage);
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
                        //     };
                        //     case(#Err(e)){
                        //         throw Error.reject("401: Error: "#e);
                        //     };
                        // };
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
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
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
    private func _local_signTx(_txi: TxIndex) : async* {txi: Nat; signature: Blob; rawTx: [Nat8]; txHash: TxHash}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
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
                        case(?#EIP1559(txObj), ?(raw, hash)){
                            let signature = await* _sign(dpath, Blob.fromArray(hash));
                            let signValues = await* ETHCrypto.convertSignature(Blob.toArray(signature), raw, tx.from, ck_chainId, utils_);
                            let txObjNew: Transaction = #EIP1559({
                                to = txObj.to;
                                value = txObj.value;
                                max_priority_fee_per_gas = txObj.max_priority_fee_per_gas; 
                                data = txObj.data;
                                sign = ?{r = signValues.r; s = signValues.s; v = signValues.v; from = ABI.fromHex(tx.from); hash = hash };
                                max_fee_per_gas = txObj.max_fee_per_gas;
                                chain_id = txObj.chain_id;
                                nonce = txObj.nonce;
                                gas_limit = txObj.gas_limit;
                                access_list = txObj.access_list;
                            });
                            // 0x2 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, signatureYParity, signatureR, signatureS])
                            // switch(await utils.encode_signed_transaction(txObjNew)){
                            //     case(#Ok(signedTx, signedHash)){
                                    let signedTx = ETHCrypto.rlpEncode(txObjNew);
                                    let signedHash = ETHCrypto.sha3(signedTx);
                                    // var signedHash : [Nat8] = []; 
                                    // try{
                                    //     // countAsyncMessage += 1;
                                    //     signedHash := await utils.keccak256(signedTx);
                                    //     // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                                    // }catch(e){
                                    //     // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                                    //     throw Error.reject("Calling error: "# Error.message(e)); 
                                    // };
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
                                // };
                                // case(#Err(e)){
                                //     throw Error.reject("401: Error: "#e);
                                // };
                            // };
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
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                if (tx.status == #Sending){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
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
                                    if (Text.contains(e, #text "no consensus was reached") or Text.contains(e, #text "already known")){
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
    
    // Local task entrance
    private func _local(_args: SagaTM.CallType, _receipt: ?SagaTM.Receipt) : async (SagaTM.TaskResult){
        switch(_args){
            case(#This(method)){
                switch(method){
                    case(#getNonce(_txi, _toids)){
                        let result = await* _local_getNonce(_txi, _toids);
                        return (#Done, ?#This(#getNonce(result)), null);
                    };
                    case(#createTx(_txi)){
                        let result = await* _local_createTx(_txi);
                        return (#Done, ?#This(#createTx(result)), null);
                    };case(#createTx_comp(_txi)){
                        let result = await* _local_createTx_comp(_txi);
                        return (#Done, ?#This(#createTx_comp(result)), null);
                    };
                    case(#signTx(_txi)){
                        let result = await* _local_signTx(_txi);
                        return (#Done, ?#This(#signTx(result)), null);
                    };
                    case(#sendTx(_txi)){
                        let result = await* _local_sendTx(_txi);
                        return (#Done, ?#This(#sendTx(result)), null);
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
    private var saga: ?SagaTM.SagaTM = null;
    private func _getSaga() : SagaTM.SagaTM {
        switch(saga){
            case(?(_saga)){ return _saga };
            case(_){
                let _saga = SagaTM.SagaTM(Principal.fromActor(this), ?_local, null, null); //?_taskCallback, ?_orderCallback
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
                    let sagaRes = await* saga.getActuator().run();
                    // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                }catch(e){
                    // countAsyncMessage -= Nat.min(1, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            }else{
                try{
                    // countAsyncMessage += 2;
                    let sagaRes = await saga.run(_toid);
                    // countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    // countAsyncMessage -= Nat.min(2, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            };
        };
    };
    private func _buildTask(_data: ?Blob, _callee: Principal, _callType: SagaTM.CallType, _preTtid: [SagaTM.Ttid], _cycles: Nat) : SagaTM.PushTaskRequest{
        return {
            callee = _callee;
            callType = _callType;
            preTtid = _preTtid;
            attemptsMax = ?3;
            recallInterval = ?200000000; // nanoseconds
            cycles = _cycles;
            data = _data;
        };
    };
    private func _checkICTCError() : (){
        let count = _getSaga().getActuator().getErrorLogs(1, 10).total;
        if (count >= countICTCError + 5){
            countICTCError := count;
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
            if (status != ?#Done and status != ?#Recovered){
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
    // private func _addEthNonce(_a: AccountId): (){
    //     switch(Trie.get(accounts, keyb(_a), Blob.equal)){
    //         case(?(account, nonce)){ 
    //             accounts := Trie.put(accounts, keyb(_a), Blob.equal, (account, nonce + 1)).0; 
    //         };
    //         case(_){};
    //     };
    // };
    private func _setEthNonce(_a: AccountId, _nonce: Nonce): (){
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account, nonce)){ 
                accounts := Trie.put(accounts, keyb(_a), Blob.equal, (account, _nonce)).0; 
            };
            case(_){};
        };
    };
    private func _getEthNonce(_a: AccountId): Nonce{
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account, nonce)){ return nonce; };
            case(_){ return 0; };
        };
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
        if (_amount > 0){
            feeBalances := Trie.put(feeBalances, keyb(tokenId), Blob.equal, balance).0;
        };
        return balance;
    };
    private func _subFeeBalance(_tokenId: EthAddress, _amount: Wei): (balance: Wei){
        var balance = _getFeeBalance(_tokenId);
        balance -= _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (_amount > 0){
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
        balance -= _amount;
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
    private func _getPendingDepositTxn(_txHash: TxHash) : ?Minter.PendingDepositTxn{
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        return Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal);
    };
    private func _putPendingDepositTxn(_account: Account, _txHash: TxHash, _signature: [Nat8]) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(txHash), Blob.equal, (_txHash, _account, _signature, false, _now())).0;
    };
    private func _verifyPendingDepositTxn(_txHash: TxHash) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        switch(Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal)){
            case(?(pending)){
                pendingDepositTxns := Trie.put(pendingDepositTxns, keyb(txHash), Blob.equal, (pending.0, pending.1, pending.2, true, pending.4)).0;
            };
            case(_){};
        };
    };
    private func _removePendingDepositTxn(_txHash: TxHash) : (){
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        pendingDepositTxns := Trie.remove(pendingDepositTxns, keyb(txHash), Blob.equal).0;
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
    private func _isExistedTxn(_txHash: TxHash) : Bool{
        let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        return Option.isSome(Trie.get(depositTxns, keyb(txHash), Blob.equal)) or 
        Option.isSome(Trie.get(pendingDepositTxns, keyb(txHash), Blob.equal));
    };
    private func _isPendingTxn(_txHash: TxHash) : Bool{
        // if (not(_isExistedTxn(_txHash))){
        //     return false;
        // }; // in depositTxns or pendingDepositTxns
        // let txHash = Blob.fromArray(Option.get(ABI.fromHex(_txHash), []));
        // var status: Status = #Pending;
        // switch(Trie.get(depositTxns, keyb(txHash), Blob.equal)){
        //     case(?(item, ts)){ status := item.status };
        //     case(_){};
        // };
        // return status == #Pending; // or status == #Unknown; //status != #Confirmed and status != #Failure;
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
    private func _getEthGas(_tokenId: EthAddress) : { gasPrice: Wei; gasLimit: Nat; maxFee: Wei;}{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let gasLimit = _getGasLimit(_tokenId);
        var maxFee = gasLimit * (ck_gasPrice/* + PRIORITY_FEE_PER_GAS*/);
        return { gasPrice = ck_gasPrice/* + PRIORITY_FEE_PER_GAS*/; gasLimit = gasLimit; maxFee = maxFee; };
    };
    private func _getFixedFee(_tokenId: EthAddress): {eth: Wei; token: Wei}{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        return {
            eth = tokenInfo.fee.fixedFee;
            token = tokenInfo.fee.fixedFee * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _getCkFee(_tokenId: EthAddress): {eth: Wei; token: Wei}{
        let tokenInfo = _getCkTokenInfo(_tokenId);
        let gas = _getEthGas(_tokenId); // ETH
        return {
            eth = gas.maxFee + tokenInfo.fee.fixedFee;
            token = (gas.maxFee + tokenInfo.fee.fixedFee) * tokenInfo.fee.ethRatio / gwei_;
        };
    };
    private func _getCkFeeForDepositing(_tokenId: EthAddress): {eth: Wei; token: Wei}{
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
    private func _getCkFeeForDepositing2(_tokenId: EthAddress, _ethGas: { gasPrice: Wei; gasLimit: Nat; maxFee: Wei;}): {eth: Wei; token: Wei}{
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
        let mainAccount = {owner = Principal.fromActor(this); subaccount = null};
        let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
        let feeTempAccount = {owner = Principal.fromActor(this); subaccount = ?sa_two};
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
                                    ignore _subFeeBalance(tokenId, balance);
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
                                    let pair: ICDex.Self = actor(Principal.toText(dexPair));
                                    let ckTokenFee = await icrc1.icrc1_fee();
                                    if (balance > ckTokenFee*10){
                                        let amount = Nat.sub(balance, ckTokenFee);
                                        // tranfer fee to feeTempAccount
                                        switch(await* _sendCkToken2(tokenId, Blob.fromArray(sa_one), {owner = feeTempAccount.owner; subaccount = _toSaBlob(feeTempAccount.subaccount)}, amount)){
                                            case(#Ok(blockNum)){
                                                ignore _subFeeBalance(tokenId, balance);
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
                        ignore _subBalance(mainAccount, eth_, feeBalance);
                        ignore _addFeeBalance(eth_, feeAmount);
                    };
                    case(#Err(e)){};
                };
            };
        }
    };
    private func _getMinterBalance(_token: ?EthAddress, _enPause: Bool) : async* Minter.BalanceStats{
        let tokenId = _toLower(Option.get(_token, eth_));
        let mainAccount = {owner = Principal.fromActor(this); subaccount = null };
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(mainAccount.owner, mainAccount.subaccount));
        let nativeBalance = await* _fetchBalance(tokenId, mainAddress, true);
        let ckLedger = _getCkLedger(tokenId);
        let ckTotalSupply = await ckLedger.icrc1_total_supply();
        let ckFeetoBalance = await ckLedger.icrc1_balance_of({owner = Principal.fromActor(this); subaccount = _toSaBlob(?sa_one) });
        let minterBalance = _getBalance(mainAccount, tokenId);
        if (_enPause and _ictcAllDone()
        and nativeBalance < Nat.sub(ckTotalSupply, ckFeetoBalance) * 98 / 100 or nativeBalance < minterBalance * 95 / 100){ /*config*/
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
        let accountId = _accountId(_account.owner, _account.subaccount);
        let isERC20 = _tokenId != eth_;
        // let fee = _getEthGas(_tokenId);
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
                let txTs: Timestamp = Option.get(_update.ts, ts);
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
    private func _coverTx(_txi: TxIndex, _resetNonce: Bool, _refetchGasPrice: ?Bool, _amountSub: Wei, _autoAdjustAmount: Bool) : async* ?BlockHeight{
        if (Option.get(_refetchGasPrice, false) or _now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let gasPrice = await* _fetchGasPrice();
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
                    for (toid in tx.toids.vals()){
                        if (_onlyBlocking(toid)){
                            let r = await* _getSaga().complete(toid, #Recovered);
                            //let r = await* _getSaga().done(toid, #Recovered, true);
                        };
                    };
                    if (not(_ictcDone(tx.toids))){
                        throw Error.reject("402: ICTC has orders in progress!");
                    };
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
                            ignore _mintCkToken(tx.tokenId, feeAccount, feeDiff, ?_txi);
                            ignore _subFeeBalance(eth_, feeDiffEth);
                            ignore _burnCkToken(eth_, Blob.fromArray(sa_one), feeDiffEth, feeAccount);
                        };
                        // ICTC
                        var preTids: [Nat] = [];
                        let saga = _getSaga();
                        if (feeDiffEth > 0 and tx.txType == #Deposit and isERC20){
                            let (userAddress, userNonce) = _getEthAddressQuery(accountId);
                            let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
                            let txi0 = _newTx(#DepositGas, tx.account, eth_, mainAddress, userAddress, feeDiffEth, networkFee);
                            let txi0Blob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi0))); 
                            let toid0 : Nat = saga.create("deposit_gas_for_covering", #Forward, ?accountId, null);
                            let task0_1 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#getNonce(txi0, ?[toid0])), [], 0);
                            let ttid0_1 = saga.push(toid0, task0_1, null, null);
                            let task0_2 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#createTx(txi0)), [], 0);
                            let ttid0_2 = saga.push(toid0, task0_2, null, null);
                            let task0_3 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#signTx(txi0)), [], 0);
                            let ttid0_3 = saga.push(toid0, task0_3, null, null);
                            let task0_4 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#sendTx(txi0)), [], 0);
                            let ttid0_4 = saga.push(toid0, task0_4, null, null);
                            preTids := [ttid0_4];
                            saga.close(toid0);
                            _updateTxToids(txi0, [toid0]);
                            ignore _putEvent(#depositGas({txIndex = txi0; toid = toid0; account = tx.account; address = userAddress; amount = feeDiffEth}), ?accountId);
                        };
                        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
                        let toid : Nat = saga.create("cover_tx", #Forward, ?accountId, null);
                        if (_resetNonce){
                            let task0 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(_txi, ?[toid])), preTids, 0);
                            let ttid0 = saga.push(toid, task0, null, null);
                            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(_txi)), [], 0);
                            let ttid1 = saga.push(toid, task1, null, null);
                        }else{
                            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(_txi)), preTids, 0);
                            let ttid1 = saga.push(toid, task1, null, null);
                        };
                        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(_txi)), [], 0);
                        let ttid2 = saga.push(toid, task2, null, null);
                        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(_txi)), [], 0);
                        let ttid3 = saga.push(toid, task3, null, null);
                        saga.close(toid);
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
        switch(await utils.pub_to_address(own_public_key)){
            case(#Ok(account)){
                own_account := account;
                own_address := ABI.toHex(account);
            };
            case(#Err(e)){
                throw Error.reject("401: Error while getting address!");
            };
        };
        return (own_public_key, own_account, own_address);
    };
    private func _sign(_dpath: DerivationPath, _messageHash : Blob) : async* Blob {
        Cycles.add(ECDSA_SIGN_CYCLES);
        let res = await ic.sign_with_ecdsa({
            message_hash = _messageHash;
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = KEY_NAME; };
        });
        res.signature
    };

    public query func rpc_call_transform(raw : IC.TransformArgs) : async IC.HttpResponsePayload {
        return RpcCaller.transform(raw);
    };
    private func _fetchEthCall(_rpcUrl: Text, _methodName: Text, _params: Text, _responseSize: Nat64, _requestId: Nat): async* (Nat, Minter.RPCResult){
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\""# _methodName #"\",\"params\": "# _params #",\"id\":"# Nat.toText(id) #"}";
        rpcId += 1;
        _preRpcLog(id, _rpcUrl, input);
        Cycles.add(RPC_AGENT_CYCLES);
        // let res = await rpc.json_rpc(input, _responseSize, #url_with_api_key(_rpcUrl));
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
            var logId : RpcId = rpcId;
            var result: Text = "";
            var values: [Value] = [];
            var error: Text = "";
            var status: RpcRequestStatus = #pending; // {#pending; #ok: [Value]; #err: Text};
            try{
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
                        _postRpcLog(id, ?r, ?error);
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
                        _postRpcLog(id, null, ?e);
                        throw Error.reject(e);
                    };
                };
                _updateRpcProviderStats(keeper, true);
            }catch(e){
                error := Error.message(e);
                if (Text.contains(error, #text "Returns error:")){ 
                    _updateRpcProviderStats(keeper, true);
                }else{
                    _updateRpcProviderStats(keeper, false);
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
        while(not(isConfirmed) and i < size){
            let (keeper, rpcUrl, size) = _getRpcUrl(offset + i);
            i += 1;
            let log = await* _request(keeper, rpcUrl, requestId);
            let status_ = _putRpcRequestLog(requestId, log, minConfirmationNum);
            requestStatus := status_;
            switch(requestStatus){
                case(#ok(v)){ isConfirmed := true };
                case(_){};
            };
            // switch(log.status){
            //     case(#ok(v)){
            //         return v;
            //     };
            //     case(_){throw Error.reject("pending");};
            // };
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
        let (keeper, rpcUrl, size) = _getRpcUrl(0);
        let minRpcRequests : Nat = size;
        let params = "[]";
        ck_chainId := await* _fetchNumber("eth_chainId", params, 1000, minRpcRequests, "result");
        return ck_chainId;
    };
    private func _fetchGasPrice() : async* Nat {
        let minRpcRequests : Nat = 1;
        let params = "[]";
        let value = await* _fetchNumber("eth_gasPrice", params, 1000, minRpcRequests, "result");
        ck_gasPrice := value * 115 / 100 + 100000000; 
        lastGetGasPriceTime := _now();
        return ck_gasPrice;
    };
    private func _fetchBlockNumber() : async* Nat{
        let minRpcRequests : Nat = 1;
        let params = "[]";
        let value = await* _fetchNumber("eth_blockNumber", params, 1000, minRpcRequests, "result");
        if (value >= ck_ethBlockNumber.0){
            ck_ethBlockNumber := (value, _now());
        }else{
            throw Error.reject("BlockNumber is wrong!");
        };
        return ck_ethBlockNumber.0;
    };
    private func _fetchAccountNonce(_address: EthAddress, _blockNumber:{#latest; #pending;}) : async* Nonce{
        let minRpcRequests : Nat = 1;
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
            var logId : RpcId = rpcId;
            var result: Text = "";
            var values: [Value] = [];
            var error: Text = "";
            var status: RpcRequestStatus = #pending; // {#pending; #ok: [Value]; #err: Text};
            try{
                let (id, res) = await* _fetchEthCall(rpcUrl, _methodName, _params, _responseSize, requestId);
                logId := id;
                switch(res){
                    case(#Ok(r)){
                        result := r;
                        switch(ETHCrypto.getBytesFromJson(r, _jsonPath)){ //*
                            case(?(value)){ 
                                _postRpcLog(id, ?r, null);
                                values := [#Raw(value)];
                                status := #ok(values);
                                possibleResult := ABI.toHex(value); //*
                            }; 
                            case(_){
                                switch(ETHCrypto.getStringFromJson(r, "error/message")){
                                    case(?(value)){ 
                                        _postRpcLog(id, null, ?("Returns error: "# value));
                                        throw Error.reject("Returns error: "# value);
                                    }; 
                                    case(_){
                                        _postRpcLog(id, null, ?"Error in parsing json");
                                        throw Error.reject("Error in parsing json");
                                    };
                                };
                            };
                        };
                    };
                    case(#Err(e)){ //*
                        _postRpcLog(id, null, ?e);
                        throw Error.reject(e);
                    };
                };
                _updateRpcProviderStats(keeper, true);
            }catch(e){
                error := Error.message(e);
                if (Text.contains(error, #text "no consensus was reached") or Text.contains(error, #text "already known")){ 
                    _updateRpcProviderStats(keeper, true);
                    values := [#Text(error)];
                    status := #ok(values);
                    if (possibleResult.size() == 0){
                        possibleResult := error;
                    };
                }else if (Text.contains(error, #text "nonce too low")){ 
                    _updateRpcProviderStats(keeper, true); // Not rpc node failure
                    status := #err("Not sure if it has been successful: " # error);
                }else if (Text.contains(error, #text "Returns error:")){ 
                    _updateRpcProviderStats(keeper, true); 
                    status := #err(error);
                }else{
                    _updateRpcProviderStats(keeper, false);
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
        while(not(isConfirmed) and i < size){
            let (keeper, rpcUrl, size) = _getRpcUrl(offset + i);
            i += 1;
            let log = await* _request(keeper, rpcUrl, requestId);
            requestStatus := _putRpcRequestLog(requestId, log, minRpcRequests);
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
        let minRpcRequests : Nat = 1;
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
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0);
        let ttid = saga.push(toid, task, null, null);
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
    private func _mintCkToken(tokenId: EthAddress, account: Account, amount: Wei, txi: ?TxIndex) : SagaTM.Toid{
        // mint ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(Option.get(txi, 0)))); 
        let accountId = _accountId(account.owner, account.subaccount);
        let icrc1Account : ICRC1.Account = { owner = account.owner; subaccount = _toSaBlob(account.subaccount); };
        let (userAddress, userNonce) = _getEthAddressQuery(accountId);
        let saga = _getSaga();
        let toid : Nat = saga.create("mint", #Forward, ?accountId, null);
        let args : ICRC1.TransferArgs = {
            from_subaccount = null;
            to = icrc1Account;
            amount = amount;
            fee = null;
            memo = switch(ABI.fromHex(userAddress)){ case(?memo){ ?Blob.fromArray(memo) }; case(_){ null }; };
            created_at_time = null; // nanos
        };
        let task = _buildTask(?txiBlob, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0);
        let ttid = saga.push(toid, task, null, null);
        saga.close(toid);
        ignore _putEvent(#mint({toid = toid; account = account; icTokenCanisterId = ckTokenCanisterId; amount = amount}), ?accountId);
        return toid;
    };
    private func _burnCkToken(tokenId: EthAddress, fromSubaccount: Blob, amount: Wei, account: Account) : SagaTM.Toid{
        // burn ckToken
        let ckTokenCanisterId = _getCkTokenInfo(tokenId).ckLedgerId;
        let accountId = _accountId(account.owner, account.subaccount);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let saga = _getSaga();
        let toid : Nat = saga.create("burn", #Forward, ?accountId, null);
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?fromSubaccount;
            to = mainIcrc1Account;
            amount = amount;
            fee = null;
            memo = null;
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(burnArgs)), [], 0);
        let ttid = saga.push(toid, task, null, null);
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
            ignore _subFeeBalance(eth_, _value);
            let toid = _sendCkToken(eth_, Blob.fromArray(sa_one), _account, Nat.sub(_value, ckFee));
            await* _ictcSagaRun(toid, false);
        };
    };
    private func _syncTxStatus(_txIndex: TxIndex, _immediately: Bool) : async* (){
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts, cts)){
                let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                if ((tx.status == #Sending or tx.status == #Submitted or tx.status == #Pending)
                and (_immediately or (_now() > ts + 90  and _ictcDone(tx.toids)) )){
                    let txHashs = tx.txHash;
                    var status = tx.status;
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
                        if (succeeded and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirmations){
                            status := #Confirmed;
                            receiptTemp := res;
                            if (tx.txType == #Deposit and _isPending(_txIndex)){ // _isPending()
                                let isERC20 = tx.tokenId != eth_;
                                let gasFee = tx.fee; //_getEthGas(tx.tokenId); // eth Wei // Getting the fee from the tx record
                                let ckFee = _getCkFeeForDepositing2(tx.tokenId, tx.fee); // {eth; token} Wei // Getting the fee from the tx record
                                var amount: Wei = tx.amount;
                                var fee: Wei = 0;
                                if (isERC20){
                                    fee := ckFee.token;
                                    amount -= fee;
                                    ignore _addFeeBalance(tx.tokenId, fee);
                                    let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                                    ignore _mintCkToken(tx.tokenId, feeAccount, fee, ?_txIndex);
                                }else{
                                    fee := Nat.sub(ckFee.eth, gasFee.maxFee);
                                    amount -= fee;
                                    ignore _addFeeBalance(tx.tokenId, fee);
                                    let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                                    ignore _mintCkToken(tx.tokenId, feeAccount, fee, ?_txIndex);
                                };
                                ignore _addBalance(tx.account, tx.tokenId, amount);
                                ignore _removeDepositingTxIndex(accountId, _txIndex);
                                ignore _putEvent(#depositResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=amount; fee = ?fee})), ?accountId);
                                _stats(tx.tokenId, #Minting, amount);
                            }else if(tx.txType == #DepositGas and _isPending(_txIndex)){ // _isPending()
                                ignore _putEvent(#depositGasResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=tx.amount})), ?accountId);
                            }else if(tx.txType == #Withdraw and _isPending(_txIndex)){ // _isPending()
                                _removeRetrievingTxIndex(_txIndex);
                                ignore _putEvent(#withdrawResult(#ok({txIndex = _txIndex; account = tx.account; token=tx.tokenId; txid=tx.txHash; amount=tx.amount})), ?accountId);
                                _stats(tx.tokenId, #Retrieval, tx.amount);
                            };
                            break TxReceipt;
                        }else if (succeeded and (blockHeight == 0 or _getBlockNumber() < blockHeight + minConfirmations)){
                            status := #Pending;
                            receiptTemp := res;
                        }else if (not(succeeded) and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirmations){
                            countFailure += 1;
                        };
                    };
                    if (countFailure == txHashs.size() and _isPending(_txIndex)){ // _isPending()
                        status := #Failure;
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
                            ts = ?_now();
                        }, null);
                    }else if (_isPending(_txIndex)){// _isPending()
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
                };
            };
            case(_){};
        };
    };
    private func _depositNotify(_token: ?EthAddress, _account : Account) : async* {
        #Ok : Minter.UpdateBalanceResult; 
        #Err : Minter.ResultError;
    }{
        let accountId = _accountId(_account.owner, _account.subaccount);
        let account = _account;
        let (userAddress, userNonce) = _getEthAddressQuery(accountId);
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
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
            if (isERC20 and txi > 0){
                await* _syncTxStatus(Nat.sub(txi, 1), false); // Depost Gas
            };
            await* _syncTxStatus(txi, false); // Deposit
            return #Err(#GenericError({code = 402; message="402: You have a deposit waiting for network confirmation."}));
        }else{ // New deposit
            depositAmount := await* _fetchBalance(tokenId, userAddress, true); // Wei  
        };
        if (depositAmount > ckFee.token and depositAmount > _getTokenMinAmount(tokenId) and Option.isNull(_getDepositingTxIndex(accountId))){ 
            var amount = depositAmount;
            if (isERC20){
                if (_getFeeBalance(eth_) >= networkFee.maxFee + gasFee.maxFee){
                    ignore _subFeeBalance(eth_, networkFee.maxFee + gasFee.maxFee);
                    let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                    ignore _burnCkToken(eth_, Blob.fromArray(sa_one), networkFee.maxFee + gasFee.maxFee, feeAccount);
                }else{
                    return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
                };
            }else{
                depositFee := gasFee.maxFee;
                amount -= depositFee;
            };
            var txi0 = 0; // depositing gas txn
            if (isERC20){
                txi0 := _newTx(#DepositGas, account, eth_, mainAddress, userAddress, gasFee.maxFee, networkFee);
            };
            let txi = _newTx(#Deposit, account, tokenId, userAddress, mainAddress, amount, gasFee);
            _putDepositingTxIndex(accountId, txi);
            _putAddressAccount(tokenId, userAddress, _account);
            //ICTC: 
            var preTids: [Nat] = [];
            let saga = _getSaga();
            if (isERC20){
                let txi0Blob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi0))); 
                let toid0 : Nat = saga.create("deposit_gas", #Forward, ?accountId, null);
                let task0_1 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#getNonce(txi0, ?[toid0])), [], 0);
                //let comp0_1 = _buildTask(?txi0Blob, Principal.fromActor(this), #__skip, [], 0);
                let ttid0_1 = saga.push(toid0, task0_1, null, null);
                let task0_2 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#createTx(txi0)), [], 0);
                //let comp0_2 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#createTx_comp(txi0)), [], 0);
                let ttid0_2 = saga.push(toid0, task0_2, null, null);
                let task0_3 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#signTx(txi0)), [], 0);
                //let comp0_3 = _buildTask(?txi0Blob, Principal.fromActor(this), #__block, [], 0);
                let ttid0_3 = saga.push(toid0, task0_3, null, null);
                let task0_4 = _buildTask(?txi0Blob, Principal.fromActor(this), #This(#sendTx(txi0)), [], 0);
                //let comp0_4 = _buildTask(?txi0Blob, Principal.fromActor(this), #__skip, [], 0);
                let ttid0_4 = saga.push(toid0, task0_4, null, null);
                preTids := [ttid0_4];
                saga.close(toid0);
                _updateTxToids(txi0, [toid0]);
                ignore _putEvent(#depositGas({txIndex = txi0; toid = toid0; account = _account; address = userAddress; amount = gasFee.maxFee}), ?accountId);
            };
            let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
            let toid : Nat = saga.create("deposit", #Forward, ?accountId, null);
            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), preTids, 0);
            //let comp1 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
            let ttid1 = saga.push(toid, task1, null, null);
            let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
            //let comp2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx_comp(txi)), [], 0);
            let ttid2 = saga.push(toid, task2, null, null);
            let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
            //let comp3 = _buildTask(?txiBlob, Principal.fromActor(this), #__block, [], 0);
            let ttid3 = saga.push(toid, task3, null, null);
            let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
            //let comp4 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
            let ttid4 = saga.push(toid, task4, null, null);
            saga.close(toid);
            _updateTxToids(txi, [toid]);
            await* _ictcSagaRun(toid, false);
            ignore _putEvent(#deposit({txIndex = txi; toid = toid; account = _account; address = userAddress; token = tokenId; amount = amount; fee = ?depositFee}), ?accountId);
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
    private var lastUpdateBalanceTime : Nat = 0;
    private func _updateBalance(): async* (){
        for ((accountId, tokenBalances) in Trie.iter(balances)){
            if (_notPaused() and accountId != _accountId(Principal.fromActor(this), null)){ // Non-pool account
                for((tokenIdBlob, (account, x)) in Trie.iter(tokenBalances)){
                    let tokenId = ABI.toHex(Blob.toArray(tokenIdBlob));
                    let isERC20 = tokenId != eth_;
                    let icrc1Account : ICRC1.Account = { owner = account.owner; subaccount = _toSaBlob(account.subaccount); };
                    let (userAddress, userNonce) = _getEthAddressQuery(accountId);
                    let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
                    let txi = _getDepositingTxIndex(accountId);
                    if (_now() >= lastUpdateBalanceTime + 60){
                        switch(txi){
                            case(?(txi_)){ // Method-1
                                if (isERC20 and txi_ > 0){
                                    await* _syncTxStatus(Nat.sub(txi_,1), false); // isERC20: Deposit Gas
                                };
                                await* _syncTxStatus(txi_, false); // Deposit ETH/ERC20
                            };
                            case(_){}; // Method-2
                        };
                    };
                    let depositingBalance = _getBalance(account, tokenId);
                    if (depositingBalance > 0){
                        ignore _subBalance(account, tokenId, depositingBalance);
                        ignore _addBalance({owner = Principal.fromActor(this); subaccount = null}, tokenId, depositingBalance);
                        // mint ckToken
                        let toid = _mintCkToken(tokenId, account, depositingBalance, txi);
                        await* _ictcSagaRun(toid, false);
                    };
                };
            };
        };
        lastUpdateBalanceTime := _now();
    };
    private func _coverPendingTxs(): async* (){
        for ((accountId, txi) in Trie.iter(deposits)){
            switch(Trie.get(transactions, keyn(txi), Nat.equal)){
                case(?(tx, ts, cts)){
                    // 20 minutes
                    let coveredTs = Option.get(cts, ts);
                    if (_now() > coveredTs + 20*60 and Array.size(tx.txHash) < 6){
                        try{
                            await* _syncTxStatus(txi, true);
                            ignore await* _coverTx(txi, false, ?true, 0, true);
                        }catch(e){};
                    };
                };
                case(_){};
            };
        };
    };
    private var lastUpdataBalanceForMode2Time : Nat = 0;
    private func _updataBalanceForMode2() : async* (){
        if (_notPaused() and _now() >= lastUpdataBalanceForMode2Time + 60 and _now() > lastUpdateMode2TxnTime + 15){
            lastUpdataBalanceForMode2Time := _now();
            lastUpdateMode2TxnTime := _now();
            let mainAccoundId = _accountId(Principal.fromActor(this), null);
            let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccoundId);
            label Tasks for ((k, (_txHash, _account, _signature, _isVerified, _ts)) in Trie.iter(pendingDepositTxns)){
                lastUpdateMode2TxnTime := _now();
                let accountId = _accountId(_account.owner, _account.subaccount);
                try{
                    if (_isPendingTxn(_txHash)){
                        let (succeeded, txn, blockHeight, status, txNonce, jsons) = await* _fetchTxn(_txHash);
                        switch(succeeded, txn, blockHeight, status){
                            case(true, ?(tokenTxn), blockHeight, #Confirmed){
                                if (not(_isCkToken(tokenTxn.token)) and _isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"Not a supported token.");
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "Not a supported token."})), ?accountId);
                                    continue Tasks;
                                };
                                if (_getBlockNumber() > blockHeight + VALID_BLOCKS_FOR_CLAIMING_TXN and _isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?("It has expired (valid for "# Nat.toText(VALID_BLOCKS_FOR_CLAIMING_TXN) #" blocks)."));
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "It expired (valid for 648000 blocks)."})), ?accountId);
                                    continue Tasks;
                                };
                                if (mainAddress != tokenTxn.to and _isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"The recipient is not the ck address of this Canister.");
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "The recipient is not the ck address of this Canister."})), ?accountId);
                                    continue Tasks;
                                };
                                if (tokenTxn.value == 0 and _isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"The value of the transaction cannot be zero.");
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "The value of the transaction cannot be zero."})), ?accountId);
                                    continue Tasks;
                                };
                                let message = _depositingMsg(_txHash, _account);
                                let rsv = await* ETHCrypto.convertSignature(_signature, message, tokenTxn.from, ck_chainId, utils_);
                                let address = await* ETHCrypto.recover(rsv, ck_chainId, message, utils_);
                                if (address == tokenTxn.from){ 
                                    _verifyPendingDepositTxn(_txHash); // verified
                                    _putDepositTxn(_account, _txHash, _signature, #Pending, null, null);
                                    let (succeeded, blockHeight, txStatus, jsons) = await* _fetchTxReceipt(_txHash);
                                    if (succeeded and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirmations and _isPendingTxn(_txHash)){
                                        let isERC20 = tokenTxn.token != eth_;
                                        //let gasFee = _getEthGas(tokenTxn.token); // {.... maxFee }eth Wei
                                        let ckFee = _getFixedFee(tokenTxn.token); // {eth; token} Wei 
                                        var amount: Wei = tokenTxn.value;
                                        var fee: Wei = ckFee.token;
                                        if (amount > fee){
                                            amount -= fee;
                                            ignore _addFeeBalance(tokenTxn.token, fee);
                                            let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                                            ignore _mintCkToken(tokenTxn.token, feeAccount, fee, null);
                                            ignore _addBalance(_account, tokenTxn.token, amount);
                                            _confirmDepositTxn(_txHash, #Confirmed, ?(tokenTxn), ?_now(), null);
                                            _removePendingDepositTxn(_txHash);
                                            _putAddressAccount(tokenTxn.token, tokenTxn.from, _account);
                                            _putTxAccount(tokenTxn.token, _txHash, tokenTxn.from, _account);
                                            ignore _putEvent(#claimDepositResult(#ok({token = tokenTxn.token; account = _account; from = tokenTxn.from; amount = amount; fee = ?fee; txHash = _txHash; signature = ABI.toHex(_signature)})), ?accountId);
                                            _stats(tokenTxn.token, #Minting, amount);
                                        }else{
                                            _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"The amount is too low.");
                                            _removePendingDepositTxn(_txHash);
                                            ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "The amount is too low."})), ?accountId);
                                        };
                                    }else if (succeeded and (blockHeight == 0 or _getBlockNumber() < blockHeight + minConfirmations) and _isPendingTxn(_txHash)){
                                        //
                                    }else if (not(succeeded) and blockHeight > 0 and _getBlockNumber() >= blockHeight + minConfirmations and _isPendingTxn(_txHash)){
                                        _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"Transaction failure.");
                                        _removePendingDepositTxn(_txHash);
                                        ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "Transaction failure."})), ?accountId);
                                    }else if (not(succeeded) and _isPendingTxn(_txHash)){
                                        _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"Fetching transaction receipt error.");
                                        _removePendingDepositTxn(_txHash);
                                        ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "Fetching transaction receipt error."})), ?accountId);
                                    };
                                }else if (_isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"Signature verification failure.");
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "Signature verification failure."})), ?accountId);
                                };
                            };
                            case(true, ?(tokenTxn), blockHeight, #Pending){
                                if (_isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Pending, null, ?"The transaction is pending.");
                                };
                            };
                            case(false, _, _, _){
                                if (_now() > _ts + 20*60 and _isPendingTxn(_txHash)){
                                    _putDepositTxn(_account, _txHash, _signature, #Failure, null, ?"Error: The transaction was not found within 20 minutes. Please wait for the transaction confirmation and submit again.");
                                    _removePendingDepositTxn(_txHash);
                                    ignore _putEvent(#claimDepositResult(#err({account = _account; txHash = _txHash; signature = ABI.toHex(_signature); error = "Error: The transaction was not found within 20 minutes. Please wait for the transaction confirmation and submit again."})), ?accountId);
                                }else{
                                    // will retry
                                }; 
                            };
                            case(_, _, _, _){
                                // will retry
                            };
                        };
                    }else{
                        if (_now() > _ts + 20*60) { _removePendingDepositTxn(_txHash); };
                    };
                }catch(e){
                    if (app_debug) { throw Error.reject(Error.message(e)) };
                };
            };
            await* _updateBalance();
        };
    };
    private var lastUpdateRetrievalsTime : Nat = 0;
    private func _updateRetrievals() : async* [(Minter.TxStatus, Timestamp)]{
        if (_now() >= lastUpdateRetrievalsTime + 60 and _now() > lastUpdateTxsTime + 15){
            lastUpdateRetrievalsTime := _now();
            lastUpdateTxsTime := _now();
            for (txi in List.toArray(pendingRetrievals).vals()){
                lastUpdateTxsTime := _now();
                await* _syncTxStatus(txi, false);
            };
            let retrievals = List.toArray(List.mapFilter<TxIndex, (Minter.TxStatus, Timestamp)>(pendingRetrievals, func (txi: TxIndex): ?(Minter.TxStatus, Timestamp){
                switch(Trie.get(transactions, keyn(txi), Nat.equal)){
                    case(?(tx, ts, cts)){
                        if (_now() > ts + 600){ return ?(tx, ts) }else{ return null};
                    };
                    case(_){ return null };
                };
            }));
            return retrievals;
        };
        return [];
    };

    private func _calcuConfirmations(_stats: [([Value], Nat)], _value: [Value]) : ([Value], Nat, [([Value], Nat)]){
        var isMatched: Bool = false;
        var value: [Value] = [];
        var num: Nat = 0;
        var newStats: [([Value], Nat)] = [];
        for ((v, n) in _stats.vals()){
            if (v == _value){
                isMatched := true;
                newStats := Tools.arrayAppend(newStats, [(v, n + 1)]);
                if (n+1 > num){
                    value := v;
                    num := n + 1;
                };
            }else{
                newStats := Tools.arrayAppend(newStats, [(v, n)]);
                if (n > num){
                    value := v;
                    num := n;
                };
            };
        };
        if (not(isMatched) and _value.size() > 0){
            newStats := Tools.arrayAppend(newStats, [(_value, 1)]);
            if (num == 0){
                value := _value;
                num := 1;
            };
        };
        return (value, num, newStats);
    };
    private func _putRpcRequestLog(_rid: RpcRequestId, _log: RpcFetchLog, _minConfirmedNum: Nat): RpcRequestStatus{
        let thisSucceedNum : Nat = switch(_log.status){ case(#ok(v)){ 1 }; case(_){ 0 } };
        var consResult: RpcRequestStatus = #pending;
        switch(Trie.get(ck_rpcRequests, keyn(_rid), Nat.equal)){
            case(?(requestLog)){
                var confirmedNum = requestLog.confirmed;
                consResult := requestLog.status;
                var requests: [RpcFetchLog] = requestLog.requests;
                var confirmations: [([Value], Nat)] = [];
                requests := Tools.arrayAppend(requests, [_log]);
                if (thisSucceedNum > 0){
                    for (log in requests.vals()){
                        switch(log.status){
                            case(#ok(v)){
                                let (value, maxConfirmedNum, stats) = _calcuConfirmations(confirmations, v);
                                confirmedNum := maxConfirmedNum;
                                confirmations := stats;
                                if (confirmedNum >= _minConfirmedNum){
                                    consResult := #ok(value);
                                };
                            };
                            case(_){};
                        };
                    };
                };
                ck_rpcRequests := Trie.put(ck_rpcRequests, keyn(_rid), Nat.equal, {
                    confirmed = confirmedNum; 
                    status = consResult;
                    requests = requests; 
                }).0;
            };
            case(_){
                if (thisSucceedNum > 0 and thisSucceedNum >= _minConfirmedNum){
                    consResult := _log.status;
                };
                ck_rpcRequests := Trie.put(ck_rpcRequests, keyn(_rid), Nat.equal, {
                    confirmed = thisSucceedNum; 
                    status = consResult;
                    requests = [_log]; 
                }).0;
            };
        };
        return consResult;
    };
    private func _updateRpcProviderStats(_keeper: AccountId, _isSuccess: Bool): (){
        switch(Trie.get(ck_rpcProviders, keyb(_keeper), Blob.equal)){
            case(?(provider)){
                var preHealthCheck = provider.preHealthCheck;
                var healthCheck = provider.healthCheck;
                if (_now() >= lastHealthinessSlotTime + healthinessIntervalSeconds){
                    lastHealthinessSlotTime := _now() / healthinessIntervalSeconds * healthinessIntervalSeconds;
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
                if (recentPersistentErrors >= (if (app_debug){ 10 }else{ 6 }) or (healthCheck.calls >= 20 and healthCheck.errors * 100 / healthCheck.calls > 30)){
                    status := #Unavailable;
                };
                ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(_keeper), Blob.equal, {
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
        let (keeper, url, total) = _getRpcUrl(0);
        if (total < minRpcConfirmations){
            paused := true;
            ignore _putEvent(#suspend({message = ?"Insufficient number of available RPC nodes."}), ?_accountId(Principal.fromActor(this), null));
        };
    };
    private func _preRpcLog(_id: RpcId, _url: Text, _input: Text) : (){
        switch(Trie.get(ck_rpcLogs, keyn(_id), Nat.equal)){
            case(?(log)){ assert(false) };
            case(_){ 
                ck_rpcLogs := Trie.put(ck_rpcLogs, keyn(_id), Nat.equal, {
                    url= _url;
                    time = _now(); 
                    input = _input; 
                    result = null; 
                    err = null
                }).0; 
            };
        };
    };
    private func _postRpcLog(_id: RpcId, _result: ?Text, _err: ?Text) : (){
        switch(Trie.get(ck_rpcLogs, keyn(_id), Nat.equal)){
            case(?(log)){
                ck_rpcLogs := Trie.put(ck_rpcLogs, keyn(_id), Nat.equal, {
                    url = log.url;
                    time = log.time; 
                    input = log.input; 
                    result = _result; 
                    err = _err
                }).0; 
            };
            case(_){};
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
            _now() < v + 24*3600
        });
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

    /** Public functions **/
    /// Deposit Method : 1
    public shared(msg) func get_deposit_address(_account : Account): async EthAddress{
        assert(_notPaused() or _onlyOwner(msg.caller));
        assert(depositMethod == 1 or depositMethod == 3);
        let accountId = _accountId(_account.owner, _account.subaccount);
        if (Option.isSome(_getDepositingTxIndex(accountId))){
            throw Error.reject("405: You have a deposit waiting for network confirmation.");
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
        assert(depositMethod == 1 or depositMethod == 3);
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        // };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        _setLatestVisitTime(msg.caller);
        let res = await* _depositNotify(_token, _account);
        await* _updateBalance(); // for all accounts
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
        assert(depositMethod == 2 or depositMethod == 3);
        assert(_txHash.size() == 66); // text
        assert(_signature.size() == 64 or _signature.size() == 65);
        let accountId = _accountId(_account.owner, _account.subaccount);
        //let tokenId = _toLower(Option.get(_token, eth_));
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        _setLatestVisitTime(msg.caller);
        let txHash = _toLower(_txHash);
        if (_isConfirmedTxn(txHash) or _isPendingTxn(txHash)){ // important!
            await* _updataBalanceForMode2();
            return #Err(#GenericError({ message = "TxHash already exists."; code = 402 }))
        };
        _putPendingDepositTxn(_account, txHash, _signature);
        _putDepositTxn(_account, txHash, _signature, #Pending, null, null);
        let blockIndex = _putEvent(#claimDeposit({account = _account; txHash = txHash; signature = ABI.toHex(_signature)}), ?accountId);
        await* _updataBalanceForMode2();
        return #Ok(blockIndex);
    };
    public shared(msg) func update_claims() : async (){
        // for all users
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     throw Error.reject("405: IC network is busy, please try again later.");
        // };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        _setLatestVisitTime(msg.caller);
        await* _updataBalanceForMode2();
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
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        // };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        _setLatestVisitTime(msg.caller);
        let accountId = _accountId(msg.caller, _sa);
        let account: Minter.Account = {owner=msg.caller; subaccount=_sa};
        let withdrawalIcrc1Account: ICRC1.Account = {owner=Principal.fromActor(this); subaccount=?accountId};
        let withdrawalAccount : Minter.Account = { owner = msg.caller; subaccount = ?Blob.toArray(accountId); };
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccoundId);
        let toAddress = _toLower(_address);
        if (Text.size(_address) != 42){
            return #Err(#GenericError({code = 402; message="402: Address is not available."}));
        };
        if (List.size(pendingRetrievals) >= MAX_PENDING_RETRIEVALS){
            return #Err(#GenericError({code = 402; message="402: There are too many retrieval operations and the system is busy, please try again later."}));
        };
        let tokenId = _toLower(Option.get(_token, eth_));
        let isERC20 = tokenId != eth_;
        // let icrc1Fee = ckethFee_; // Wei
        if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let _gasPrice = await* _fetchGasPrice();
        };
        let gasFee = _getEthGas(tokenId); // for ETH or ERC20
        let ckFee = _getCkFee(tokenId); // {eth; token} Wei 
        //AmountTooLow
        var sendingAmount = _amount;
        var sendingFee: Wei = 0;
        if (_amount > ckFee.token and _amount >= _getTokenMinAmount(tokenId)){
            sendingFee := ckFee.token;
            sendingAmount -= sendingFee;
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
        if (_getBalance({owner = Principal.fromActor(this); subaccount = null }, tokenId) < _amount){
            return #Err(#GenericError({code = 402; message="402: Insufficient pool balance."}));
        };
        //Insufficient fee balance
        if (_getFeeBalance(eth_) < gasFee.maxFee){
            return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
        };
        //Burn
        switch(await* _burnCkToken2(tokenId, accountId, _address, _amount, account)){
            case(#Ok(height)){
                ignore _subBalance({owner = Principal.fromActor(this); subaccount = null }, tokenId, _amount); 
                ignore _addFeeBalance(tokenId, ckFee.token);
                let feeAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one};
                ignore _mintCkToken(tokenId, feeAccount, ckFee.token, null);
                ignore _subFeeBalance(eth_, gasFee.maxFee);
                ignore _burnCkToken(eth_, Blob.fromArray(sa_one), gasFee.maxFee, feeAccount);
                //totalSent += _amount;
                let txi = _newTx(#Withdraw, account, tokenId, mainAddress, toAddress, sendingAmount, gasFee);
                let status : Minter.RetrieveStatus = {
                    account = account;
                    retrieveAccount = withdrawalAccount;
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
                let toid : Nat = saga.create("retrieve", #Forward, ?accountId, null);
                let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
                let ttid1 = saga.push(toid, task1, null, null);
                let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
                let ttid2 = saga.push(toid, task2, null, null);
                let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
                let ttid3 = saga.push(toid, task3, null, null);
                let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
                let ttid4 = saga.push(toid, task4, null, null);
                saga.close(toid);
                _updateTxToids(txi, [toid]);
                await* _ictcSagaRun(toid, false);
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
    public shared(msg) func update_retrievals() : async (sending: [(Minter.TxStatus, Timestamp)]){
        // for all users
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        // if (not(_checkAsyncMessageLimit())){
        //     countRejections += 1; 
        //     throw Error.reject("405: IC network is busy, please try again later.");
        // };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        _setLatestVisitTime(msg.caller);
        return await* _updateRetrievals();
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
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        _setLatestVisitTime(msg.caller);
        let accountId = _accountId(msg.caller, _sa);
        assert((_onlyTxCaller(accountId, _txi) and _notPaused()) or _onlyOwner(msg.caller));
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts, cts)){
                let coveredTs = Option.get(cts, ts);
                if (_now() < coveredTs + 20*60){ // 20 minuts
                    throw Error.reject("400: Please do this 20 minutes after the last status update. Last Updated: " # Nat.toText(coveredTs) # " (timestamp).");
                };
                if (Array.size(tx.txHash) > 5){
                    throw Error.reject("400: Covering the transaction can be submitted up to 5 times.");
                };
                // let isERC20 = tx.tokenId != eth_;
                // assert(not(isERC20 and tx.txType == #Deposit)); // #Deposit: only for eth
            };
            case(_){};
        };
        await* _syncTxStatus(_txi, true);
        return await* _coverTx(_txi, false, ?true, 0, true);
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
        return _getPendingDepositTxn(_txHash);
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
        for ((txHashId, (txHash, account, signature, isVerified, ts)) in Trie.iter(pendingDepositTxns)){
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
        return _getDepositTxn(_txHash);
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

    /* ===========================
      Keeper section
    ============================== */
    // variant{put = record{"RPC1"; "..."; variant{Available}}}, null
    public shared(msg) func keeper_setRpc(_act: {#remove; #put:(name: Text, url: Text, status: {#Available; #Unavailable})}, _sa: ?Sa) : async Bool{ 
        let accountId = _accountId(msg.caller, _sa);
        assert(_onlyKeeper(accountId));
        switch(_act){
            case(#remove){
                ck_rpcProviders := Trie.remove(ck_rpcProviders, keyb(accountId), Blob.equal).0;
            };
            case(#put(name, url, status)){
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
        let res = trieItems<AccountId, Keeper>(ck_keepers, 1, 2000);
    };
    public query func get_rpc_providers(): async TrieList<AccountId, RpcProvider>{
        let res = trieItems<AccountId, RpcProvider>(ck_rpcProviders, 1, 2000);
        return {
            data = Array.map<(AccountId, RpcProvider), (AccountId, RpcProvider)>(res.data, func (t:(AccountId, RpcProvider)): (AccountId, RpcProvider){
                (t.0, {
                    name = t.1.name; 
                    url = "***" # ETHCrypto.strRight(t.1.url, 4); 
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
    public shared(msg) func setDependents(_utilsCanisterId: Principal) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        utils_ := _utilsCanisterId;
        ignore _putEvent(#config({setting = #dependents({utilsTool = _utilsCanisterId})}), ?_accountId(owner, null));
        return true;
    };
    public shared(msg) func setDepositMethod(_depositMethod: Nat8) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        depositMethod := _depositMethod;
        ignore _putEvent(#config({setting = #depositMethod(_depositMethod)}), ?_accountId(owner, null));
        return true;
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
                // if (_status == #Disabled){
                //     switch(Trie.get(ck_rpcProviders, keyb(accountId), Blob.equal)){
                //         case(?(provider)){
                //             ck_rpcProviders := Trie.put(ck_rpcProviders, keyb(accountId), Blob.equal, {
                //                 name = provider.name; 
                //                 url = provider.url; 
                //                 keeper = provider.keeper;
                //                 status = #Unavailable; 
                //                 calls = provider.calls; 
                //                 errors = provider.errors; 
                //                 preHealthCheck = provider.preHealthCheck;
                //                 healthCheck = provider.healthCheck;
                //                 latestCall = provider.latestCall;
                //             }).0;
                //         };
                //         case(_){};
                //     };
                // };
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
                        ts = ?_now();
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
        return await* _coverTx(_txi, _resetNonce, ?_refetchGasPrice, _amountSub, _autoAdjust);
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
                    // ICTC
                    let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
                    let saga = _getSaga();
                    saga.open(_toid);
                    var preTtid0: [Nat] = [];
                    if (_resetNonce){
                        let task0 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(_txi, ?[_toid])), [], 0);
                        let ttid0 = saga.appendComp(_toid, 0, task0, null);
                        preTtid0 := [ttid0];
                    };
                    let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(_txi)), preTtid0, 0);
                    let ttid1 = saga.appendComp(_toid, 0, task1, null);
                    let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(_txi)), [ttid1], 0);
                    let ttid2 = saga.appendComp(_toid, 0, task2, null);
                    let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(_txi)), [ttid2], 0);
                    let ttid3 = saga.appendComp(_toid, 0, task3, null);
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
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
        let ttid2 = saga.push(toid, task2, null, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
        let ttid3 = saga.push(toid, task3, null, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
        let ttid4 = saga.push(toid, task4, null, null);
        saga.close(toid);
        await* _ictcSagaRun(toid, false);
        return toid;
    };
    public shared(msg) func updateMinterBalance(_token: ?EthAddress, _surplusToFee: Bool) : async {pre: Minter.BalanceStats; post: Minter.BalanceStats; shortfall: Wei}{
        // Warning: To ensure the accuracy of the balance update, it is necessary to wait for the minimum required number of block confirmations before calling this function after suspending the contract operation.
        // WARNING: If you want to attribute the surplus tokens to the FEE balance, you need to make sure all claim operations for the cross-chain transactions have been completed.
        assert(_onlyOwner(msg.caller));
        assert(_ictcAllDone());
        let tokenId = _toLower(Option.get(_token, eth_));
        let mainAccount = {owner = Principal.fromActor(this); subaccount = null };
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(mainAccount.owner, mainAccount.subaccount));
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
                ckTotalSupply -= value;
                ckFeetoBalance -= value;
                ignore _burnCkToken(tokenId, Blob.fromArray(sa_one), value, {owner = Principal.fromActor(this); subaccount = ?sa_one });
            } else if (ckTotalSupply < nativeBalance and _surplusToFee){
                let value = Nat.sub(nativeBalance, ckTotalSupply);
                ckTotalSupply += value;
                ckFeetoBalance += value;
                ignore _mintCkToken(tokenId, {owner = Principal.fromActor(this); subaccount = ?sa_one }, value, null);
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
    // variant{ETH=record{quoteToken="0xefa83712d45ee530ac215b96390a663c01f2fee0";dexPair=principal "tkrhr-gaaaa-aaaak-aeyaq-cai"}}
    // variant{ERC20=record{tokenId="0x9813ad2cacba44fc8b099275477c9bed56c539cd";dexPair=principal "twv5a-raaaa-aaaak-aeycq-cai"}}
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
        assert(_version != _getLatestIcrc1Wasm().1);
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
            let wasm = _getLatestIcrc1Wasm();
            return (wasm.1, wasm.0.size());
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
        Cycles.add(INIT_CKTOKEN_CYCLES);
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
            }));
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
                name = name; 
                symbol = symbol; 
                metadata = null; 
                founder = null;
            }));
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
    public shared(msg) func clearRpcLogs(_clearFrom: RpcId, _clearTo: RpcId) : async (){
        assert(_onlyOwner(msg.caller));
        assert(_clearTo >= _clearFrom);
        for (i in Iter.range(_clearFrom, _clearTo)){
            ck_rpcLogs := Trie.remove(ck_rpcLogs, keyn(i), Nat.equal).0;
        };
        firstRpcId := _clearTo + 1;
    };
    public shared(msg) func clearRpcRequests(_clearFrom: RpcRequestId, _clearTo: RpcRequestId) : async (){
        assert(_onlyOwner(msg.caller));
        assert(_clearTo >= _clearFrom);
        for (i in Iter.range(_clearFrom, _clearTo)){
            ck_rpcRequests := Trie.remove(ck_rpcRequests, keyn(i), Nat.equal).0;
        };
        firstRpcRequestId := _clearTo + 1;
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
    // public shared(msg) func debug_clear_pendingDepositTxns() : async (){
    //     assert(_onlyOwner(msg.caller));
    //     pendingDepositTxns := Trie.filter<TxHashId, Minter.PendingDepositTxn>(pendingDepositTxns, func (k: TxHashId, v: Minter.PendingDepositTxn): Bool{
    //         _now() < v.4 + 90*24*3600 // about 90 days of ether network
    //     });
    // };
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
        // assert(_onlyOwner(msg.caller));
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
    public shared(msg) func debug_local_signTx(_txi: TxIndex) : async ({txi: Nat; signature: Blob; rawTx: [Nat8]; txHash: TxHash}){
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
    public shared(msg) func debug_parse_tx(_data: Blob): async ETHUtils.Result_2{
        assert(_onlyOwner(msg.caller));
        return await utils.parse_transaction(Blob.toArray(_data));
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
        let toid : Nat = saga.create("send_to", #Backward, ?accountId, null);
        let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
        let comp1 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid1 = saga.push(toid, task1, ?comp1, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
        let comp2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx_comp(txi)), [], 0);
        let ttid2 = saga.push(toid, task2, ?comp2, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
        let comp3 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid3 = saga.push(toid, task3, ?comp3, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
        let comp4 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid4 = saga.push(toid, task4, ?comp4, null);
        saga.close(toid);
        _updateTxToids(txi, [toid]);
        await* _ictcSagaRun(toid, false);
        // testMainnet := false;
        return txi;
    };
    public shared(msg) func debug_verify_sign(_signer: EthAddress, _account : Account, _txHash: TxHash, _signature: [Nat8]) : async (Text, {r: [Nat8]; s: [Nat8]; v: Nat64}, EthAddress){
        assert(_onlyOwner(msg.caller));
        let message = _depositingMsg(_txHash, _account);
        let rsv = await* ETHCrypto.convertSignature(_signature, message, _signer, ck_chainId, utils_);
        let address = await* ETHCrypto.recover(rsv, ck_chainId, message, utils_);
        return (ABI.toHex(message), rsv, address);
    };
    public shared(msg) func debug_sha3(_msg: Text): async Text{
        assert(_onlyOwner(msg.caller));
        let hex = ABI.toHex(ETHCrypto.sha3(Blob.toArray(Text.encodeUtf8(_msg))));
        assert(hex == ABI.toHex(await utils.keccak256(Blob.toArray(Text.encodeUtf8(_msg)))));
        return hex;
    };
    public shared(msg) func debug_updateBalance(): async (){
        assert(_onlyOwner(msg.caller));
        await* _updateBalance();
    };
    public shared(msg) func debug_updataBalanceForMode2(): async (){
        assert(_onlyOwner(msg.caller));
        lastUpdataBalanceForMode2Time := 0;
        lastUpdateMode2TxnTime := 0;
        await* _updataBalanceForMode2();
    };
    public shared(msg) func debug_updateRetrievals(): async (){
        assert(_onlyOwner(msg.caller));
        lastUpdateRetrievalsTime := 0;
        lastUpdateTxsTime := 0;
        ignore await* _updateRetrievals();
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
        cyclesMonitor := await* CyclesMonitor.monitor(Principal.fromActor(this), cyclesMonitor, INIT_CKTOKEN_CYCLES / (if (app_debug) {2} else {1}), INIT_CKTOKEN_CYCLES * 50, 500000000);
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
    public query func ictc_getTO(_toid: SagaTM.Toid) : async ?SagaTM.Order{
        return _getSaga().getOrder(_toid);
    };
    public query func ictc_getTOs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Toid, SagaTM.Order)]; totalPage: Nat; total: Nat}{
        return _getSaga().getOrders(_page, _size);
    };
    public query func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order)]{
        return _getSaga().getAliveOrders();
    };
    public query func ictc_getTT(_ttid: SagaTM.Ttid) : async ?SagaTM.TaskEvent{
        return _getSaga().getActuator().getTaskEvent(_ttid);
    };
    public query func ictc_getTTByTO(_toid: SagaTM.Toid) : async [SagaTM.TaskEvent]{
        return _getSaga().getTaskEvents(_toid);
    };
    public query func ictc_getTTs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Ttid, SagaTM.TaskEvent)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getTaskEvents(_page, _size);
    };
    public query func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task)]{
        let pool = _getSaga().getActuator().getTaskPool();
        let arr = Array.map<(SagaTM.Ttid, SagaTM.Task), (SagaTM.Ttid, SagaTM.Task)>(pool, 
        func (item:(SagaTM.Ttid, SagaTM.Task)): (SagaTM.Ttid, SagaTM.Task){
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
    public shared(msg) func ictc_appendTT(_businessId: ?Blob, _toid: SagaTM.Toid, _forTtid: ?SagaTM.Ttid, _callee: Principal, _callType: SagaTM.CallType, _preTtids: [SagaTM.Ttid]) : async SagaTM.Ttid{
        // Governance or manual compensation (operation allowed only when a transaction order is in blocking status).
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.open(_toid);
        let taskRequest = _buildTask(_businessId, _callee, _callType, _preTtids, 0);
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
        let accepted = Cycles.accept(amout);
    };
    /// timer tick
    // public shared(msg) func timer_tick(): async (){
    //     //
    // };

    private func timerLoop() : async (){
        if (_now() > lastMonitorTime + 2 * 24 * 3600){
            try{ 
                cyclesMonitor := await* CyclesMonitor.monitor(Principal.fromActor(this), cyclesMonitor, INIT_CKTOKEN_CYCLES / (if (app_debug) {2} else {1}), INIT_CKTOKEN_CYCLES * 50, 0);
                lastMonitorTime := _now();
             }catch(e){};
        };
        if (_notPaused()){
            try{ await* _updateTokenEthRatio() }catch(e){};
            try{ await* _convertFees() }catch(e){}; /*config*/
            try{ await* _reconciliation() }catch(e){}; /*config*/
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
            try{ await* _updataBalanceForMode2() }catch(e){};
            try{ ignore await* _updateRetrievals() }catch(e){};
            try{ await* _updateBalance() }catch(e){};
            try{ await* _coverPendingTxs() }catch(e){};
        };
    };
    private var timerId: Nat = 0;
    private var timerId2: Nat = 0;
    public shared(msg) func timerStart(_intervalSeconds1: Nat, _intervalSeconds2: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(timerId2);
        timerId := Timer.recurringTimer(#seconds(_intervalSeconds1), timerLoop);
        timerId2 := Timer.recurringTimer(#seconds(_intervalSeconds2), timerLoop2);
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
    private stable var __sagaDataNew: ?SagaTM.Data = null;
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
        timerId := Timer.recurringTimer(#seconds(if (app_debug) {3600*2} else {1800}), timerLoop);
        timerId2 := Timer.recurringTimer(#seconds(if (app_debug) {300} else {120}), timerLoop2);
    };

};