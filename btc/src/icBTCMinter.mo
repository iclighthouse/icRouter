/**
 * Module     : icBTC Minter
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */
///
/// ## Overview
///
/// icRouter enables the integration of Bitcoin and IC network through the Threshold Signature Scheme (TSS, also known as chain-key 
/// technology). icBTCs are 1:1 ICRC1 tokens minted cross-chain from Bitcoin to the IC network, and you can retrieve the original BTCs 
/// at any time. this is all done in a bridgeless manner, and its security depends on the security of the IC network.
///
/// ## Concepts
/// 
/// ### TSS and chain-key
///
/// Threshold Signature Scheme (TSS) is a multi-signature scheme that does not require the exposure of private keys and is well 
/// suited for 100% chain implementation of cross-chain transactions, which is also referred to as chain-key technology on IC.
///
/// ### External Chain and Coordinating chain
/// 
/// External Chain is a blockchain that integrates with IC network, such as bitcoin network.  
/// Coordinating chain is the blockchain where decentralised cross-chain smart contracts are located, in this case IC.
///
/// ### Original token and Wrapped token
/// 
/// Original tokens are tokens issued on external chain, such as BTC.  
/// Wrapped tokens are tokens that have been wrapped by a smart contract with a 1:1 correspondence and issued on IC, such as icBTC.
///
/// ### Minting and Retrieval
///
/// Minting is the process of locking the original tokens of an external chain into the Minter contract of the coordinating chain 
/// and issuing the corresponding wrapped tokens. Retrieval is burning the wrapped tokens and sending the corresponding original 
/// tokens in the Minter contract to the holder.
/// 
/// ## How it works
/// 
/// icRouter's btcMinter Canister enables communication with the Bitcoin network by calling the chain-key interface of the IC network, 
/// which has a dedicated subnet to provide block data and threshold ECDSA signatures, and to provide consensus.
/// 
/// ### Minting: BTC -> icBTC
/// 
/// Cross-chaining native BTC to the IC network requires three steps:
/// - (1) The user calls get_btc_address() method of btcMinter to get the deposit address of external chain, which is different for 
/// each user. It has no plaintext private key and is decentrally controlled by a dedicated subnet of the IC using TSS technology.
/// - (2) The user sends BTC in his/her BTC wallet to the above deposit address.
/// - (3) After waiting for transaction confirmation, the user calls update_balance() method of btcMinter to mint the corresponding 
/// icBTC in IC network. Native BTC UTXOs are controlled by the btcMinter canister, and the 1:1 corresponding icBTC are ICRC1 tokens 
/// on the IC network.
/// 
/// ### Retrieval: icBTC -> BTC
///
/// Retrieving native BTC from the IC network requires three steps.
/// - (1) The user gets the withdrawal address of IC (owner is btcMinter canister-id, subaccount is user account-id), or he can 
/// call btcMinter's get_withdrawal_account() method to get it (this is a query method, so needs to pay attention to its security).
/// - (2) The user sends icBTC to the above withdrawal address and burns them.
/// - (3) The user calls btcMinter's retrieve_btc() method to provide his/her BTC address of external chain and retrieve the native BTC. 
/// In this process, the BTCs that were originally stored in the btcMinter canister are sent to the destination address using the 
/// TSS technique.

import Trie "mo:base/Trie"; // "./lib/Elastic-Trie";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Deque "mo:base/Deque";
import Cycles "mo:base/ExperimentalCycles";
import ICRC1 "mo:icl/ICRC1";
import Binary "mo:icl/Binary";
import Tools "mo:icl/Tools";
import SagaTM "mo:ictc/SagaTM";
import DRC207 "mo:icl/DRC207";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Result "mo:base/Result";
import EcdsaTypes "mo:icl/bitcoin/ecdsa/Types";
import P2pkh "mo:icl/bitcoin/lib/P2pkh";
// import BitcoinTx "mo:icl/bitcoin/lib/Bitcoin";
import Address "mo:icl/bitcoin/lib/Address";
import Transaction "mo:icl/bitcoin/lib/Transaction";
import Script "mo:icl/bitcoin/lib/Script";
import Publickey "mo:icl/bitcoin/ecdsa/Publickey";
import Der "mo:icl/bitcoin/ecdsa/Der";
import Affine "mo:icl/bitcoin/ec/Affine";
import TxInput "mo:icl/bitcoin/lib/TxInput";
import TxOutput "mo:icl/bitcoin/lib/TxOutput";
import ICBTC "mo:icl/Bitcoin";
import Utils "mo:icl/bitcoin/Utils";
import Minter "mo:icl/icBTCMinter";
import Timer "mo:base/Timer";
import IC "mo:icl/IC";
import Hex "mo:icl/Hex";
import CyclesMonitor "mo:icl/CyclesMonitor";
import KYT "mo:icl/KYT";
import ICEvents "mo:icl/ICEvents";
import DRC20 "mo:icl/DRC20";
import ICTokens "mo:icl/ICTokens";
import Backup "lib/BackupTypes";
import Prim "mo:⛔";

/// 
/// ## Deployment
/// 
/// args:
/// - initArgs:
///     - retrieve_btc_min_amount : Nat64; // Minimum number of BTC that can be retrieved (satoshi).
///     - min_confirmations : ?Nat32; // The minimum confirmation blocks for a transaction on bitcoin network.
///     - fixed_fee : Nat; // Fixed fee (satoshi) that will be charged for each operation (mint/retrieve).
///     - dex_pair: ?Principal; // icBTC trading pair on ICDex (optional).
/// - enDebug: Bool; // Whether to start debugging.
/// Note: 
/// - These parameters filled in will take effect each time you upgrade.
/// - btcMinter calls bitcoin mainnet data (ecdsa_key_name == "key_1").
///
/// ## API
///

// e.g. record{retrieve_btc_min_amount=20000; min_confirmations=opt 6; fixed_fee=10; dex_pair=null}, true/false
shared(installMsg) actor class icBTCMinter(initArgs: Minter.InitArgs, enDebug: Bool) = this {
    assert(Option.get(initArgs.min_confirmations, 0:Nat32) > 3); /*config*/
    type Network = Minter.BtcNetwork;
    type Account = Minter.Account;
    type Address = ICBTC.BitcoinAddress; // not Minter.BitcoinAddress
    type TypeAddress = Minter.TypeAddress;
    type Satoshi = ICBTC.Satoshi; // Nat64
    type Utxo = ICBTC.Utxo; // not Minter.Utxo
    type MillisatoshiPerByte = ICBTC.MillisatoshiPerByte;
    type PublicKey = EcdsaTypes.PublicKey;
    type Transaction = Transaction.Transaction;
    type Script = Script.Script;
    type SighashType = Nat32;
    type Cycles = Nat;
    type Timestamp = Nat; // seconds
    type Sa = [Nat8];
    type BlockHeight = Nat64;
    type AccountId = Blob;
    type PubKey = Minter.PubKey;
    type DerivationPath = Minter.DerivationPath;
    type VaultUtxo = Minter.VaultUtxo;
    type Txid = Blob;
    type TxIndex = Nat;
    type Event = Minter.Event;
    type EventOldVerson = Minter.EventOldVerson;
    type EventBlockHeight = Minter.EventBlockHeight;
    type ListPage = Minter.ListPage;
    type ListSize = Minter.ListSize;
    type TrieList<K, V> = Minter.TrieList<K, V>;
    type SignFun = (Text, [Blob], Blob) -> async Blob;
    type CustomCallType = {
        #buildTx: (txi: Nat);
        #sendTx: (txi: Nat, txid: [Nat8]);
    };

    let CURVE = ICBTC.CURVE;
    let SIGHASH_ALL : SighashType = 0x01;
    let NETWORK : Network = #Mainnet; /*config*/
    let KEY_NAME : Text = "key_1"; /*config*/
    let MIN_CONFIRMATIONS : Nat32 = Option.get(initArgs.min_confirmations, 6:Nat32);
    let BTC_MIN_AMOUNT: Nat64 = initArgs.retrieve_btc_min_amount;
    let GET_UTXOS_COST_CYCLES : Cycles = 10_000_000_000;
    let GET_CURRENT_FEE_PERCENTILES_COST_CYCLES : Cycles = 100_000_000;
    let SEND_TRANSACTION_BASE_COST_CYCLES : Cycles = 5_000_000_000;
    let SEND_TRANSACTION_COST_CYCLES_PER_BYTE : Cycles = 20_000_000;
    let ECDSA_SIGN_CYCLES : Cycles = 30_000_000_000;
    let ICTC_RUN_INTERVAL : Nat = 10;
    let MIN_VISIT_INTERVAL : Nat = 30; //seconds
    let AVG_TX_BYTES : Nat64 = 450; /*config*/
    let INIT_CKTOKEN_CYCLES: Cycles = 1000000000000; // 1T
    let SEND_TXN_INTERVAL : Nat = 600; //seconds
    
    private stable var app_debug : Bool = enDebug; // Cannot be modified
    private let version_: Text = "0.3.6"; /*config*/
    private let ns_: Nat = 1000000000;
    private let minCyclesBalance: Nat = 100_000_000_000; // 0.1 T
    private stable var pause: Bool = false;
    private stable var owner: Principal = installMsg.caller;
    private stable let ic_: Principal = Principal.fromText("aaaaa-aa"); 
    private stable var icBTC_: Principal = Principal.fromText("aaaaa-aa"); // to be configured
    private var ckFixedFee: Nat = initArgs.fixed_fee;
    private var ckDexPair: ?Principal = initArgs.dex_pair;
    private var blackhole_: Text = "7hdtw-jqaaa-aaaak-aaccq-cai";
    private let sa_one : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]; // Fees account
    private let ic : ICBTC.Self = actor(Principal.toText(ic_));
    private var icBTC : ICRC1.Self = actor(Principal.toText(icBTC_));
    private stable var icBTCFee: Nat = 20;
    private stable var btcFee: Nat64 = 3000;  // MillisatoshiPerByte
    private stable var lastUpdateFeeTime : Time.Time = 0;
    private stable var countRejections: Nat = 0;
    private stable var lastExecutionDuration: Int = 0;
    private stable var maxExecutionDuration: Int = 0;
    private stable var lastSagaRunningTime : Time.Time = 0;
    private stable var countAsyncMessage : Nat = 0;

    private stable var blockIndex : BlockHeight = 0; // @deprecated
    private stable var minterUtxos = Deque.empty<VaultUtxo>(); // (Address, PubKey, DerivationPath, Utxo);
    private stable var minterRemainingBalance : Nat64 = 0;
    private stable var totalBtcFee: Nat64 = 0;
    private stable var totalBtcReceiving: Nat64 = 0;
    private stable var totalBtcSent: Nat64 = 0;
    private stable var feeBalance : Nat64 = 0;
    private stable var accountAddresses = Trie.empty<AccountId, ([Nat8], Text)>(); 
    private stable var lastFetchUtxosTime : Time.Time = 0;
    private stable var accountUtxos = Trie.empty<Address, (PubKey, DerivationPath, [Utxo])>(); 
    private stable var depositUpdating = Trie.empty<AccountId, Timestamp>(); 
    private stable var latestVisitTime = Trie.empty<Principal, Timestamp>(); 
    private stable var retrieveBTC = Trie.empty<EventBlockHeight, Minter.RetrieveStatus>(); // retrieval Events
    private stable var sendingBTC = Trie.empty<TxIndex, Minter.SendingBtcStatus>(); // ck txns
    private stable var txInProcess : [TxIndex] = [];
    private stable var txIndex : TxIndex = 0;
    private stable var firstTxIndex : TxIndex = 0;
    private stable var lastTxTime : Time.Time = 0;
    private stable var blockEvents = Trie.empty<Nat, EventOldVerson>(); // @deprecated
    private stable var minter_public_key : [Nat8] = [];
    private stable var minter_address = "";
    private stable var icrc1WasmHistory: [(wasm: [Nat8], version: Text)] = [];
    
    // KYT
    private stable var kyt_accountAddresses: KYT.AccountAddresses = Trie.empty(); 
    private stable var kyt_addressAccounts: KYT.AddressAccounts = Trie.empty(); 
    private stable var kyt_txAccounts: KYT.TxAccounts = Trie.empty(); 
    // Events
    private stable var eventBlockIndex : EventBlockHeight = Nat64.toNat(blockIndex);
    private stable var firstBlockIndex : EventBlockHeight = Nat64.toNat(blockIndex);
    private stable var icEvents : ICEvents.ICEvents<Event> = Trie.empty(); 
    private stable var icAccountEvents : ICEvents.AccountEvents = Trie.empty(); 
    // Monitor
    private stable var cyclesMonitor: CyclesMonitor.MonitoredCanisters = Trie.empty(); 
    private stable var lastMonitorTime: Nat = 0;

    private func _addMinterUtxos(_address: Address, _pubkey: PubKey, _dpath: DerivationPath, _utxos: [Utxo]) : (){
        for (utxo in Array.reverse(_utxos).vals()){
            let vaultUtxo : VaultUtxo = (_address, _pubkey, _dpath, utxo);
            minterUtxos := Deque.pushFront(minterUtxos, vaultUtxo);
            minterRemainingBalance += utxo.value;
        };
    };
    private func _getAccountUtxos(_address: Address) : ?(PubKey, DerivationPath, [Utxo]){
        switch(Trie.get(accountUtxos, keyt(_address), Text.equal)){
            case(?(item)){ return ?item };
            case(_){ return null };
        };
    };
    private func _addAccountUtxos(_address: Address, _pubkey: PubKey, _dpath: DerivationPath, _utxos: [Utxo]) : (){
        switch(Trie.get(accountUtxos, keyt(_address), Text.equal)){
            case(?(item)){
                var preUtxos = item.2;
                if (preUtxos.size() > 2000){
                    preUtxos := Tools.slice(preUtxos, 0, ?1999);
                };
                let utxos = Tools.arrayAppend(_utxos, preUtxos);
                accountUtxos := Trie.put(accountUtxos, keyt(_address), Text.equal, (_pubkey, _dpath, utxos)).0;
            };
            case(_){
                accountUtxos := Trie.put(accountUtxos, keyt(_address), Text.equal, (_pubkey, _dpath, _utxos)).0;
            };
        };
    };
    private func _accountUtxosLatestHeight(_address: Text) : Nat32{
        switch(_getAccountUtxos(_address)){
            case(?(item)){
                if (item.2.size() > 0){
                    return item.2[0].height;
                }else{
                    return 0;
                };
            };
            case(_){
                return 0;
            };
        };
    };
    private func _getLatestVisitTime(_address: Principal) : Timestamp{
        switch(Trie.get(latestVisitTime, keyp(_address), Principal.equal)){
            case(?(v)){ return v };
            case(_){ return 0 };
        };
    };
    private func _setLatestVisitTime(_address: Principal) : (){
        latestVisitTime := Trie.put(latestVisitTime, keyp(_address), Principal.equal, _now()).0;
        latestVisitTime := Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 3600
        });
    };
    private func _dosCheck(_accountId: AccountId, _max: Nat) : Bool{
        let data = Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 30 // 30 seconds
        });
        if (Trie.size(data) >= _max){
            if(Option.isSome(Trie.get(kyt_accountAddresses, keyb(_accountId), Blob.equal))){
                return true;
            }else{
                return false;
            };
        }else{
            return true;
        };
    };

    private func _now() : Timestamp{
        return Int.abs(Time.now() / ns_);
    };
    private func _asyncMessageSize() : Nat{
        return countAsyncMessage + _getSaga().asyncMessageSize();
    };
    private func _checkAsyncMessageLimit() : Bool{
        return _asyncMessageSize() < 400; /*config*/
    };
    // cycles limit
    private func _checkCycles(): Bool{
        return Cycles.balance() > minCyclesBalance;
    };

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };

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
    private func _vaultToUtxos(_utxos: [VaultUtxo]): [Minter.Utxo]{
        var utxos : [Minter.Utxo] = [];
        for ((address, pubKey, derivationPath, utxo) in _utxos.vals()){
            utxos := Tools.arrayAppend(utxos, _toUtxosArr([utxo]));
        };
        return utxos;
    };
    private func _toUtxosArr(_utxos: [ICBTC.Utxo]): [Minter.Utxo]{
        var utxos : [Minter.Utxo] = [];
        for (utxo in _utxos.vals()){
            utxos := Tools.arrayAppend(utxos, [{
                height  = utxo.height;
                value  = utxo.value; // Satoshi
                outpoint = { txid = Blob.toArray(utxo.outpoint.txid); vout = utxo.outpoint.vout }; 
            }]);
        };
        return utxos;
    };
    private func _natToFloat(_n: Nat) : Float{
        return Float.fromInt64(Int64.fromNat64(Nat64.fromNat(_n)));
    };
    private func _fromHeight(_h: BlockHeight) : Txid{
        return Blob.fromArray(Binary.BigEndian.fromNat64(_h));
    };
    private func _toHeight(_txid: Txid) : BlockHeight{
        return Binary.BigEndian.toNat64(Blob.toArray(_txid));
    };
    private func _onlyOwner(_caller: Principal) : Bool { //ict
        return _caller == owner;
    }; 
    private func _notPaused() : Bool { 
        return not(pause);
    };

    // SagaTM
    // Local tasks
    private func _local_buildTx(_txi: Nat) : async* {txi: Nat; signedTx: [Nat8]}{ 
        switch(Trie.get(sendingBTC, keyn(_txi), Nat.equal)){
            case(?(tx)){
                if (tx.status == #Signing){
                    let signed = await* _buildSignedTx(_txi, tx.utxos, tx.destinations, tx.fee);
                    ignore _updateSendingBtc(_txi, null, null, ?signed.tx, ?#Sending({ txid = signed.txid }), [], ?[]);
                    if (tx.toids.size() > 0){
                        let toid = tx.toids[tx.toids.size()-1];
                        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi)));
                        let saga = _getSaga();
                        saga.open(toid);
                        let task = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#sendTx(_txi, signed.txid)), [], 0, null, null);
                        let _ttid = saga.push(toid, task, null, null);
                        saga.close(toid);
                    }else{
                        throw Error.reject("415: The toid does not exist!");
                    };
                    return {txi = _txi; signedTx = signed.tx };
                }else{
                    throw Error.reject("415: Transaction status is not equal to #Signing!");
                };
            };
            case(_){ throw Error.reject("415: The transaction record does not exist!"); };
        };
    };
    private func _local_sendTx(_txi: Nat, _txid: [Nat8]) : async* {txi: Nat; destinations: [(Nat64, Text, Nat64)]; txid: [Nat8]}{ 
        switch(Trie.get(sendingBTC, keyn(_txi), Nat.equal)){
            case(?(tx)){
                if (Option.isSome(tx.signedTx)){
                    let signedTx: [Nat8] = Option.get(tx.signedTx, []);
                    let transaction_fee = SEND_TRANSACTION_BASE_COST_CYCLES + signedTx.size() * SEND_TRANSACTION_COST_CYCLES_PER_BYTE;
                    Cycles.add<system>(transaction_fee);
                    await ic.bitcoin_send_transaction({ network = NETWORK; transaction = signedTx; });
                    ignore _updateSendingBtc(_txi, null, null, null, ?#Submitted({ txid = _txid }), [], ?[]);
                    var i : Nat32 = 0;
                    let eventUtxos = _vaultToUtxos(tx.utxos);
                    for (dest in tx.destinations.vals()){
                        switch(Trie.get(retrieveBTC, keyn(Nat64.toNat(dest.0)), Nat.equal)){
                            case(?(item)){ // account retrieveAccount btcAddress
                                _putAddressAccount(item.btcAddress, item.account);
                                _putAddressAccount(item.btcAddress, item.retrieveAccount);
                                _putTxAccount(Hex.encode(_txid), item.btcAddress, item.account);
                                _putTxAccount(Hex.encode(_txid), item.btcAddress, item.retrieveAccount);
                                let event : Minter.Event = #sent_transaction({account = item.account; retrieveAccount = item.retrieveAccount; address = item.btcAddress; change_output = ?{value = dest.2; vout = i }; txid = Hex.encode(_txid); utxos = eventUtxos; requests = [dest.0]; });
                                ignore _putEvent(event, ?_accountId(item.account.owner, item.account.subaccount));
                            };
                            case(_){};
                        };
                        i += 1;
                    };
                    return {txi = _txi; destinations = tx.destinations; txid = _txid };
                }else{
                    throw Error.reject("416: The signedTx field cannot be empty!");
                };
            };
            case(_){ throw Error.reject("416: The transaction record does not exist!"); };
        };
    };
    // Local task entrance
    private func _customCall(_callee: Principal, _cycles: Nat, _args: SagaTM.CallType<CustomCallType>, _receipt: ?SagaTM.Receipt) : async (SagaTM.TaskResult){
        switch(_args){
            case(#custom(method)){
                switch(method){
                    case(#buildTx(_txi)){
                        let result = await* _local_buildTx(_txi);
                        let resultRaw = Binary.BigEndian.fromNat64(Nat64.fromNat(result.txi));
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    case(#sendTx(_txi, _txid)){
                        let result = await* _local_sendTx(_txi, _txid);
                        let resultRaw = Binary.BigEndian.fromNat64(Nat64.fromNat(result.txi));
                        return (#Done, ?#result(?(resultRaw, debug_show(result))), null);
                    };
                    //case(_){return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
                };
            };
            case(_){ return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
        };
    };
    // Task callback
    // private func _taskCallback(_ttid: SagaTM.Ttid, _task: SagaTM.Task, _result: SagaTM.TaskResult) : (){
    //     //taskLogs := Tools.arrayAppend(taskLogs, [(_ttid, _task, _result)]);
    // };
    // // Order callback
    // private func _orderCallback(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _data: ?Blob) : (){
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
                    countAsyncMessage += 1;
                    let _sagaRes = await* saga.getActuator().run();
                    countAsyncMessage -= Nat.min(1, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(1, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            }else{
                try{
                    countAsyncMessage += 2;
                    let _sagaRes = await saga.run(_toid);
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
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
            pause := true;
            ignore _putEvent(#suspend({message = ?"The ICTC transaction reported errors and the system was suspended."}), ?_accountId(Principal.fromActor(this), null));
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

    // Converts a public key to a P2PKH address.
    private func _publicKeyToP2PKHAddress(_publicKeyBytes : [Nat8]) : Address {
        let publicKey = _publicKeyBytesToPublicKey(_publicKeyBytes);
        // Compute the P2PKH address from our public key.
        P2pkh.deriveAddress(#Mainnet, Publickey.toSec1(publicKey, true))
    };
    private func _publicKeyBytesToPublicKey(_publicKeyBytes : [Nat8]) : PublicKey {
        let point = Utils.unwrap(Affine.fromBytes(_publicKeyBytes, CURVE));
        Utils.get_ok(Publickey.decode(#point point))
    };
    private func _initMinterAddress() : async* (){
        if (minter_address == ""){
            let res = await* _fetchAccountAddress(Blob.fromArray([]));
            minter_public_key := res.0;
            minter_address := res.1;
        };
    };
    private func _accountId(_owner: Principal, _subaccount: ?[Nat8]) : Blob{
        return Blob.fromArray(Tools.principalToAccount(_owner, _subaccount));
    };

    private func _addFeeBalance(_amount: Nat64): (){
        feeBalance += _amount;
    };
    private func _subFeeBalance(_amount: Nat64): (){
        feeBalance -= _amount;
    };
    private func _sendCkToken(fromSubaccount: Blob, to: Account, amount: Nat64) : SagaTM.Toid{
        // send ckToken
        let ckTokenCanisterId = icBTC_;
        let toAccountId = _accountId(to.owner, to.subaccount);
        let toIcrc1Account : ICRC1.Account = {owner=to.owner; subaccount=_toSaBlob(to.subaccount) };
        let saga = _getSaga();
        let toid : Nat = saga.create("send", #Forward, ?toAccountId, null);
        let args : ICRC1.TransferArgs = {
            from_subaccount = ?fromSubaccount;
            to = toIcrc1Account;
            amount = Nat64.toNat(amount);
            fee = null;
            memo = null;
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        saga.close(toid);
        ignore _putEvent(#send({toid = ?toid; to = to; icTokenCanisterId = ckTokenCanisterId; amount = Nat64.toNat(amount)}), ?toAccountId);
        return toid;
    };
    private func _mintIcToken(optToid: ?Nat, account: Account, userAddress: Text, amount: Nat64, ictcName: ?Text) : SagaTM.Toid{
        // mint ckToken
        let ckTokenCanisterId = icBTC_;
        let accountId = _accountId(account.owner, account.subaccount);
        let icrc1Account : ICRC1.Account = { owner = account.owner; subaccount = _toSaBlob(account.subaccount); };
        let saga = _getSaga();
        var toid : Nat = 0;
        switch(optToid){
            case(?toid_){
                toid := toid_;
                saga.open(toid);
            };
            case(_){
                toid := saga.create(Option.get(ictcName, "mint"), #Forward, ?accountId, null);
            };
        };
        let args : ICRC1.TransferArgs = {
            from_subaccount = null;
            to = icrc1Account;
            amount = Nat64.toNat(amount);
            fee = null;
            memo = ?Text.encodeUtf8(userAddress);
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(args)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        ignore _putEvent(#mint({toid = ?toid; account = account; address = userAddress; icTokenCanisterId = ckTokenCanisterId; amount = Nat64.toNat(amount)}), ?accountId);
        return toid;
    };
    private func _burnCkToken(optToid: ?Nat, fromSubaccount: Blob, address: Text, amount: Nat64, account: Account, ictcName: ?Text) : SagaTM.Toid{
        // burn ckToken
        let ckTokenCanisterId = icBTC_;
        let accountId = _accountId(account.owner, account.subaccount);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let saga = _getSaga();
        var toid : Nat = 0;
        switch(optToid){
            case(?toid_){
                toid := toid_;
                saga.open(toid);
            };
            case(_){
                toid := saga.create(Option.get(ictcName, "burn"), #Forward, ?accountId, null);
            };
        };
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?fromSubaccount;
            to = mainIcrc1Account;
            amount = Nat64.toNat(amount);
            fee = null;
            memo = ?Text.encodeUtf8(address);
            created_at_time = null; // nanos
        };
        let task = _buildTask(null, ckTokenCanisterId, #ICRC1(#icrc1_transfer(burnArgs)), [], 0, null, null);
        let _ttid = saga.push(toid, task, null, null);
        ignore _putEvent(#burn({toid = ?toid; account = account; address = address; icTokenCanisterId = ckTokenCanisterId; tokenBlockIndex = 0; amount = Nat64.toNat(amount)}), ?accountId);
        return toid;
    };
    private func _burnCkTokenWithoutIctc(_fromSubaccount: Blob, _address: Text, _amount: Nat64, _account: Account) : async* { #Ok: Nat; #Err: ICRC1.TransferError; }{
        ignore await* _getSaga().getActuator().run();
        let accountId = _accountId(_account.owner, _account.subaccount);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let toAddress = _address;
        let ckLedger = icBTC;
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?_fromSubaccount;
            to = mainIcrc1Account;
            amount = Nat64.toNat(_amount);
            fee = null;
            memo = ?Text.encodeUtf8(toAddress);
            created_at_time = null; // nanos
        };
        let res = await ckLedger.icrc1_transfer(burnArgs);
        switch(res){
            case(#Ok(height)){
                ignore _putEvent(#burn({toid = null; account = _account; address = toAddress; icTokenCanisterId = icBTC_; tokenBlockIndex = height; amount = Nat64.toNat(_amount)}), ?accountId);
            };
            case(_){};
        };
        return res;
    };
    private func _sendFromFeeBalance(_account: Account, _value: Nat64): async* (){
        let icrc1: ICRC1.Self = icBTC;
        let ckFee = Nat64.fromNat(await icrc1.icrc1_fee());
        if (_value >= ckFee*2){
            _subFeeBalance(_value);
            let toid = _sendCkToken(Blob.fromArray(sa_one), _account, Nat64.sub(_value, ckFee));
            let _res = await _getSaga().run(toid);
        };
    };

    private func _getBtcFee() : async* Nat64 {
        var fees : [Nat64] = [];
        try{
            countAsyncMessage += 2;
            Cycles.add<system>(GET_CURRENT_FEE_PERCENTILES_COST_CYCLES);
            fees := await ICBTC.get_current_fee_percentiles(NETWORK);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage); 
        };
        if (fees.size() > 39) { // 39-th percentile fee. Details: https://internetcomputer.org/docs/current/developer-docs/multi-chain/bitcoin/using-btc/read-state#reading-the-fee-percentile
            return Nat64.max(fees[39], 3000); // min: 3 satoshi/B
        }else{
            return 3000;
        };
    };

    private func _fetchAccountAddress(_a: AccountId) : async* (pubKey: [Nat8], address: Text){
        var ownPublicKey : [Nat8] = [];
        var ownAddress = "";
        var dpath: [Blob] = [_a];
        if (_a == Blob.fromArray([])){
            dpath := [];
        };
        switch(Trie.get(accountAddresses, keyb(_a), Blob.equal)){
            case(?(pubKey_, address_)){
                ownPublicKey := pubKey_;
                ownAddress := address_;
            };
            case(_){
                let ecdsaPublicKey = await ic.ecdsa_public_key({
                    canister_id = null;
                    derivation_path = dpath;
                    key_id = { curve = #secp256k1; name = KEY_NAME }; //dfx_test_key
                });
                ownPublicKey := Blob.toArray(ecdsaPublicKey.public_key);
                ownAddress := _publicKeyToP2PKHAddress(ownPublicKey);
                accountAddresses := Trie.put(accountAddresses, keyb(_a), Blob.equal, (ownPublicKey, ownAddress)).0;
            };
        };
        return (ownPublicKey, ownAddress);
    };
    private func _fetchAccountUtxos(_account : ?{owner: Principal; subaccount : ?[Nat8] }): async* (address: Text, amount: Nat64, utxos: [Utxo]){
        var ownPublicKey : [Nat8] = [];
        var ownAddress = "";
        var dpath : [Blob] = [];
        switch(_account){
            case(?(account)){
                let accountId = _accountId(account.owner, account.subaccount);
                dpath := [accountId];
                try{
                    countAsyncMessage += 2;
                    let res = await* _fetchAccountAddress(accountId);
                    ownPublicKey := res.0;
                    ownAddress := res.1;
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                    throw Error.reject("410: Error in fetching public key!");
                };
            };
            case(_){
                ownPublicKey := minter_public_key;
                ownAddress := minter_address;
            };
        };
        var amount : Nat64 = 0;
        var utxos : [Utxo] = []; // BlockHeight DESC
        try {
            countAsyncMessage += 2;
            Cycles.add<system>(GET_UTXOS_COST_CYCLES);
            var utxosResponse = await ic.bitcoin_get_utxos({
                address = ownAddress;
                network = NETWORK;
                filter = ?#MinConfirmations(MIN_CONFIRMATIONS); 
            });
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            var isNewUtxos : Bool = false;
            for (utxo in utxosResponse.utxos.vals()){ // utxosResponse.utxos: BlockHeight DESC
                if (utxo.height > _accountUtxosLatestHeight(ownAddress)){
                    utxos := Tools.arrayAppend(utxos, [utxo]);
                    isNewUtxos := true;
                };
            };
            label getNextPage while (Option.isSome(utxosResponse.next_page) and isNewUtxos){
                Cycles.add<system>(GET_UTXOS_COST_CYCLES);
                utxosResponse := await ic.bitcoin_get_utxos({
                    address = ownAddress;
                    network = NETWORK;
                    filter = ?#Page(Option.get(utxosResponse.next_page, [])); 
                });
                for (utxo in utxosResponse.utxos.vals()){
                    if (utxo.height > _accountUtxosLatestHeight(ownAddress)){
                        utxos := Tools.arrayAppend(utxos, [utxo]);
                    }else{
                        break getNextPage;
                    };
                };
            };
            // store utxos
            for (utxo in Array.reverse(utxos).vals()){
                if (utxo.height > _accountUtxosLatestHeight(ownAddress)){ // Need to use _accountUtxosLatestHeight() judgement to avoid atomicity issues.
                    _addMinterUtxos(ownAddress, ownPublicKey, dpath, [utxo]);
                    _addAccountUtxos(ownAddress, ownPublicKey, dpath, [utxo]);
                    amount += utxo.value;
                };
            };
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("411: Error in bitcoin_get_utxos()!");
        };
        return (ownAddress, amount, utxos);
    };

    private func _putTxInProcess(_txi: TxIndex) : (){
        _removeTxInProcess(_txi);
        txInProcess := Tools.arrayAppend(txInProcess, [_txi]);
    };
    private func _removeTxInProcess(_txi: TxIndex) : (){
        txInProcess := Array.filter(txInProcess, func (t: TxIndex): Bool{ t != _txi });
    };
    private func _pushSendingBtc(_txIndex: Nat, _blockIndex: BlockHeight, _dstAddress: Address, _amount: Nat64) : (){
        _putTxInProcess(_txIndex);
        switch(Trie.get(sendingBTC, keyn(_txIndex), Nat.equal)){
            case(?(tx)){
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = Tools.arrayAppend(tx.destinations, [(_blockIndex, _dstAddress, _amount)]);
                    totalAmount = tx.totalAmount + _amount;
                    utxos = tx.utxos;
                    scriptSigs = tx.scriptSigs;
                    fee = tx.fee;
                    toids = tx.toids;
                    signedTx = tx.signedTx;
                    status = tx.status;
                }: Minter.SendingBtcStatus).0;
            };
            case(_){
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = [(_blockIndex, _dstAddress, _amount)];
                    totalAmount = _amount;
                    utxos = [];
                    scriptSigs = [];
                    fee = 0;
                    toids = [];
                    signedTx = null;
                    status = #Pending;
                } : Minter.SendingBtcStatus).0;
            };
        };
    };
    private func _updateSendingBtc(_txIndex: Nat, _utxos: ?[VaultUtxo], _fee: ?Nat64, _signedTx: ?[Nat8], _status: ?Minter.RetrieveBtcStatus,
    _addToid: [Nat], _addScript: ?[Script]) : Bool{
        switch(Trie.get(sendingBTC, keyn(_txIndex), Nat.equal)){
            case(?(tx)){
                var signedTx = tx.signedTx;
                if (Option.isSome(_signedTx)){
                    signedTx := _signedTx;
                };
                var scriptSigs = tx.scriptSigs;
                switch(_addScript){
                    case(?(addScript)){
                        scriptSigs := Tools.arrayAppend(scriptSigs, addScript);
                    };
                    case(_){
                        scriptSigs := []; // Clear
                    };
                };
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = tx.destinations;
                    totalAmount = tx.totalAmount;
                    utxos = Option.get(_utxos, tx.utxos);
                    scriptSigs = scriptSigs;
                    fee = Option.get(_fee, tx.fee);
                    toids = Tools.arrayAppend(tx.toids, _addToid);
                    signedTx = signedTx;
                    status = Option.get(_status, tx.status);
                }: Minter.SendingBtcStatus).0;
                switch(_status){
                    case(?#Submitted(v)){
                        _removeTxInProcess(_txIndex);
                    };
                    case(_){};
                };
                return true;
            };
            case(_){ return false };
        };
    };
    private func _sendBtc(_txIndex: ?Nat) : async* (){
        let txi = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txi), Nat.equal)){
            case(?(tx)){
                if (tx.status == #Pending){
                    var dsts : [(TypeAddress, Satoshi)] = [];
                    for ((blockIndex, address, amount) in tx.destinations.vals()){
                        dsts := Tools.arrayAppend(dsts, [(#p2pkh(address), amount)]);
                    };
                    let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi)));
                    let saga = _getSaga();
                    let toid : Nat = saga.create("retrieve", #Forward, ?txiBlob, null);
                    // build tx test
                    let (txTest, totalFee) = _buildTxTest(dsts);
                    // build
                    let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
                    Utils.get_ok_except(_buildTransaction(2, minterUtxos, dsts, Nat64.fromNat(totalFee)), "Error building transaction.");
                    ignore _updateSendingBtc(txi, ?spendUtxos, ?Nat64.fromNat(totalFee), null, ?#Signing, [toid], ?[]);
                    minterUtxos := remainingUtxos;
                    minterRemainingBalance -= totalInput;
                    // burn Fee
                    _subFeeBalance(Nat64.fromNat(totalFee));
                    let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
                    ignore _burnCkToken(?toid, Blob.fromArray(sa_one), "", Nat64.fromNat(totalFee), feetoAccount, ?"burn_fee");
                    // ictc: signs / build - send
                    let task = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#buildTx(txi)), [], 0, null, null);
                    let _ttid = saga.push(toid, task, null, null);
                    saga.close(toid);
                    // let sagaRes = await saga.run(toid);
                    if (toid > 0 and _asyncMessageSize() < 360){ 
                        lastSagaRunningTime := Time.now();
                        await* _ictcSagaRun(toid, false);
                    }; 
                }else {
                    switch(tx.status){
                        case(#Confirmed(v)){
                            _removeTxInProcess(txi);
                        };
                        case(#Submitted(v)){
                            _removeTxInProcess(txi);
                        };
                        case(_){};
                    };
                };
            };
            case(_){};
        };
    };
    // Notice: (1) For governance calls only. (2) If fee is increased, the increase needs to be less than the change balance.
    private func _reSendBtc(_txIndex: Nat, _fee: Nat) : async* (){ // retrieve governance
        let txi = _txIndex;
        switch(Trie.get(sendingBTC, keyn(txi), Nat.equal)){
            case(?(tx)){
                switch(tx.status){
                    case(#Submitted(preTxid)){
                        var dsts : [(TypeAddress, Satoshi)] = [];
                        for ((blockIndex, address, amount) in tx.destinations.vals()){
                            dsts := Tools.arrayAppend(dsts, [(#p2pkh(address), amount)]);
                        };
                        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi)));
                        let saga = _getSaga();
                        let toid : Nat = saga.create("retrieve", #Forward, ?txiBlob, null);
                        // reset fee
                        //let (txTest, feeTest) = _buildTxTest(dsts);
                        let totalFee = _fee; 
                        ignore _updateSendingBtc(txi, null, ?Nat64.fromNat(totalFee), null, ?#Signing, [toid], null);
                        // burn Fee
                        if (Nat64.fromNat(totalFee) > tx.fee){
                            let burningFee = Nat64.sub(Nat64.fromNat(totalFee), tx.fee);
                            _subFeeBalance(burningFee);
                            let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
                            ignore _burnCkToken(?toid, Blob.fromArray(sa_one), "", burningFee, feetoAccount, ?"burn_fee");
                        };
                        // ictc: signs / build - send
                        let task = _buildTask(?txiBlob, Principal.fromActor(this), #custom(#buildTx(txi)), [], 0, null, null);
                        let _ttid = saga.push(toid, task, null, null);
                        saga.close(toid);
                        // let sagaRes = await saga.run(toid);
                        if (toid > 0 and _asyncMessageSize() < 360){ 
                            lastSagaRunningTime := Time.now();
                            await* _ictcSagaRun(toid, false);
                        }; 
                    };
                    case(_){};
                };
            };
            case(_){};
        };
    };
    private func _signTxTest(transaction: Transaction, vUtxos: [VaultUtxo]) : [Nat8] { // key_name, signer
        assert(transaction.txInputs.size() == vUtxos.size());
        //let scriptSigs = Array.init<Script>(transaction.txInputs.size(), []);
        for (i in Iter.range(0, transaction.txInputs.size() - 1)) {
            switch (Address.scriptPubKey(#p2pkh(vUtxos[i].0))) {
                case (#ok(scriptPubKey)) {
                    // Obtain scriptSigs for each Tx input.
                    // let sighash = transaction.createSignatureHash(scriptPubKey, Nat32.fromIntWrap(i), SIGHASH_ALL);
                    let signature_sec = Blob.fromArray(Array.freeze(Array.init<Nat8>(64, 255))); // Test
                    let signature_der = Blob.toArray(Der.encodeSignature(signature_sec));
                    // Append the sighash type.
                    let encodedSignatureWithSighashType = Array.tabulate<Nat8>(
                        signature_der.size() + 1, func (n) {
                        if (n < signature_der.size()) {
                            signature_der[n]
                        } else {
                            Nat8.fromNat(Nat32.toNat(SIGHASH_ALL))
                        };
                    });
                    // Create Script Sig which looks like:
                    // ScriptSig = <Signature> <Public Key>.
                    let script = [
                        #data(encodedSignatureWithSighashType),
                        #data(vUtxos[i].1)
                    ];
                    transaction.txInputs[i].script := script;
                };
                // Verify that our own address is P2PKH.
                case (#err(msg)){
                    Debug.trap("It supports signing p2pkh addresses only.");
                };
            };
        };
        transaction.toBytes()
    };
    private func _buildTxTest(destinations: [(TypeAddress, Satoshi)]) : (tx: [Nat8], totalFee: Nat){ 
        let feePerByte: Nat = Nat64.toNat(btcFee);
        var totalFee : Nat = 0;
        loop {
            let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
            Utils.get_ok_except(_buildTransaction(2, minterUtxos, destinations, Nat64.fromNat(totalFee)), "Error building transaction.");
            // Sign the transaction. In this case, we only care about the size of the signed transaction, so we use a mock signer here for efficiency.
            let signedTxnBytes = _signTxTest(transaction, spendUtxos);
            let signedTxnLen : Nat = signedTxnBytes.size();
            let minFee: Nat = spendUtxos.size() * 60 * feePerByte / 1000; // Calculate the lowest fee according to the number of inputs
            let fee: Nat = Nat.max(signedTxnLen * feePerByte / 1000, minFee);
            if(fee == totalFee) { 
                Debug.print("Transaction built with fee " # debug_show(totalFee));
                return (transaction.toBytes(), totalFee);
            } else {
                totalFee := fee;
            }
        };
    };
    // build signed transaction
    private func _buildSignedTx(
        txi: Nat, 
        ownUtxos: [VaultUtxo], // -> Deque.Deque<VaultUtxo>
        destinations: [(Nat64, Address, Satoshi)], // -> [(TypeAddress, Satoshi)]
        fee: Nat64
        ) : async* {tx: [Nat8]; txid: [Nat8]} { 
        var utxos : Deque.Deque<VaultUtxo> = Deque.empty();
        var txDestinations : [(TypeAddress, Satoshi)] = [];
        for (utxo in ownUtxos.vals()){
            var dpath = utxo.2;
            if (utxo.0 == minter_address){ // fix bug
                dpath := [];
            };
            utxos := Deque.pushFront(utxos, (utxo.0, utxo.1, dpath, utxo.3));
        };
        txDestinations := Array.map<(Nat64, Address, Satoshi), (TypeAddress, Satoshi)>(destinations, func (t: (Nat64, Address, Satoshi)): (TypeAddress, Satoshi){
            (#p2pkh(t.1), t.2)
        });
        let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
        Utils.get_ok_except(_buildTransaction(2, utxos, txDestinations, fee), "414: Error building transaction.");
        let signedTxnBytes = await* _signTx(txi, transaction, spendUtxos);
        return {tx = signedTxnBytes; txid = transaction.id() };
    };
    // sign transaction
    private func _signTx(txi: Nat, transaction: Transaction, vUtxos: [VaultUtxo]) : async* [Nat8] { // key_name
        assert(transaction.txInputs.size() == vUtxos.size());
        let scriptSigs = Array.init<Script>(transaction.txInputs.size(), []);

        for (i in Iter.range(0, transaction.txInputs.size() - 1)) {
            switch (Address.scriptPubKey(#p2pkh(vUtxos[i].0))) {
                case (#ok(scriptPubKey)) {
                    // Obtain scriptSigs for each Tx input.
                    let sighash = transaction.createSignatureHash(scriptPubKey, Nat32.fromIntWrap(i), SIGHASH_ALL);
                    //let signature_sec = await signer(KEY_NAME, vUtxos[i].2, Blob.fromArray(sighash));
                    Cycles.add<system>(ECDSA_SIGN_CYCLES);
                    let res = await ic.sign_with_ecdsa({
                        message_hash = Blob.fromArray(sighash);
                        derivation_path = vUtxos[i].2;
                        key_id = {
                            curve = #secp256k1;
                            name = KEY_NAME;
                        };
                    });
                    let signature_sec = res.signature;
                    let signature_der = Blob.toArray(Der.encodeSignature(signature_sec));
                    // Append the sighash type.
                    let encodedSignatureWithSighashType = Array.tabulate<Nat8>(
                        signature_der.size() + 1, func (n) {
                        if (n < signature_der.size()) {
                            signature_der[n]
                        } else {
                            Nat8.fromNat(Nat32.toNat(SIGHASH_ALL))
                        };
                    });
                    // Create Script Sig which looks like:
                    // ScriptSig = <Signature> <Public Key>.
                    let script = [
                        #data(encodedSignatureWithSighashType),
                        #data(vUtxos[i].1)
                    ];
                    scriptSigs[i] := script;
                    ignore _updateSendingBtc(txi, null, null, null, null, [], ?[script]);
                };
                // Verify that our own address is P2PKH.
                case (#err(msg)){
                    throw Error.reject("413: It supports signing p2pkh addresses only."); 
                };
            };
        };
        // Assign ScriptSigs to their associated TxInputs.
        for (i in Iter.range(0, scriptSigs.size() - 1)) {
            transaction.txInputs[i].script := scriptSigs[i];
        };
        return transaction.toBytes();
    };
    // build transaction
    private func _buildTransaction( version : Nat32, 
        own_utxos: Deque.Deque<VaultUtxo>,
        destinations : [(TypeAddress, Satoshi)], 
        fees : Satoshi
    ) : Result.Result<(Transaction.Transaction, [VaultUtxo], Nat64, Nat64, Deque.Deque<VaultUtxo>), Text> {
        let dustThreshold : Satoshi = 500;
        let defaultSequence : Nat32 = 0xffffffff;
        if (version != 1 and version != 2) {
            return #err ("Unexpected version number: " # Nat32.toText(version))
        };
        // Collect TxOutputs, making space for a potential extra output for change.
        let txOutputs = Buffer.Buffer<TxOutput.TxOutput>(destinations.size() + 1);
        var totalSpend : Satoshi = fees;
        for ((destAddr, destAmount) in destinations.vals()) {
            switch (Address.scriptPubKey(destAddr)) {
                case (#ok(destScriptPubKey)) {
                    txOutputs.add(TxOutput.TxOutput(destAmount, destScriptPubKey));
                    totalSpend += destAmount;
                };
                case (#err(msg)) {
                    return #err(msg);
                };
            };
        };
        // Select which UTXOs to spend. 
        var availableFunds : Satoshi = 0;
        let vUtxos: Buffer.Buffer<VaultUtxo> = Buffer.Buffer(2);
        let txInputs : Buffer.Buffer<TxInput.TxInput> = Buffer.Buffer(2); // * 
        var utxos = own_utxos;
        let size = List.size(utxos.0) + List.size(utxos.1);
        var x : Nat = 0;
        label UtxoLoop while (availableFunds < totalSpend){
            switch(Deque.popBack(utxos)){
                case(?(utxosNew, (address, pubKey, dpath, utxo))){
                    x += 1;
                    if (utxo.value >= totalSpend or (utxo.value > totalSpend/2 and x > Nat.min(size, 50)) or x > Nat.min(size*2, 100)){
                        utxos := utxosNew;
                        availableFunds += utxo.value;
                        vUtxos.add((address, pubKey, dpath, utxo));
                        txInputs.add(TxInput.TxInput(utxo.outpoint, defaultSequence)); // -- 
                    }else{
                        utxos := Deque.pushFront(utxosNew, (address, pubKey, dpath, utxo));
                    };
                    if (availableFunds >= totalSpend) {
                        // We have enough inputs to cover the amount we want to spend.
                        break UtxoLoop;
                    };
                };
                case(_){ return #err("Insufficient balance"); };
            };
        };
        // If there is remaining amount that is worth considering then include a change TxOutput.
        let remainingAmount : Satoshi = availableFunds - totalSpend;
        if (remainingAmount > dustThreshold) {
            switch (Address.scriptPubKey(#p2pkh(minter_address))) {
                case (#ok(chScriptPubKey)) {
                txOutputs.add(TxOutput.TxOutput(remainingAmount, chScriptPubKey));
                };
                case (#err(msg)) {
                return #err(msg);
                };
            };
        };
        // return
        let tx = Transaction.Transaction(version, Buffer.toArray(txInputs), Buffer.toArray(txOutputs), 0);
        return #ok(tx, Buffer.toArray(vUtxos), availableFunds, totalSpend, utxos);
    };

    private func _isWaitingToSendBTC(_txIndex : ?Nat) : Bool{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                return item.status == #Pending and item.destinations.size() > 0;
            };
            case(_){ return false; };
        };
    };

    private func _sendTxs() : async* (){
        for(txi in txInProcess.vals()){
            try{
                if (txi == txIndex and Time.now() > lastTxTime + SEND_TXN_INTERVAL * ns_){
                    lastTxTime := Time.now();
                    txIndex += 1;
                    await* _sendBtc(?txi);
                }else{
                    await* _sendBtc(?txi);
                };
            }catch(e){};
        };
    };

    private func _putDepositUpdating(_a: AccountId) : (){
        depositUpdating := Trie.put(depositUpdating, keyb(_a), Blob.equal, _now()).0;
        depositUpdating := Trie.filter(depositUpdating, func (a: AccountId, ts: Timestamp): Bool{
            ts + 48 * 3600 > _now(); // 48 hours
        });
    };
    private func _removeDepositUpdating(_a: AccountId) : (){
        depositUpdating := Trie.remove(depositUpdating, keyb(_a), Blob.equal).0;
    };
    private func _isDepositUpdating(_a: AccountId) : Bool{
        switch(Trie.get(depositUpdating, keyb(_a), Blob.equal)){
            case(?ts){
                return ts + 48 * 3600 > _now(); // 48 hours
            };
            case(_){
                return false;
            };
        };
    };

    // Check the balances of icBTCMinter and deal with exceptions.
    private func _reconciliation() : async* (){
        // nativeBalance >= minterBalance
        // nativeBalance >= ckTotalSupply
        // minterBalance >= ckTotalSupply - ckFeeBalance
        _checkICTCError();
        await* _initMinterAddress();
        let nativeBalance = Nat64.toNat(minterRemainingBalance);
        let ckLedger = icBTC;
        let ckTotalSupply = await ckLedger.icrc1_total_supply();
        // let ckFeeBalance = await ckLedger.icrc1_balance_of(feetoAccount);
        let minterBalance = Nat64.toNat(totalBtcReceiving - totalBtcSent);
        // let minterFeeBalance = Nat64.toNat(feeBalance); 
        if (not(app_debug) and _ictcAllDone() and (nativeBalance < minterBalance * 98 / 100 or nativeBalance < ckTotalSupply * 95 / 100)){ /*config*/
            pause := true;
            ignore _putEvent(#suspend({message = ?"The pool account balance does not match and the system is suspended and pending DAO processing."}), ?_accountId(Principal.fromActor(this), null));
        };
    };

    // Public methds

    /// Returns the deposit address, which is different for each user. It has no plaintext private key and is decentrally 
    /// controlled by a dedicated subnet of the IC using TSS technology.
    public shared(msg) func get_btc_address(_account : Account): async Text{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        let (pubKey, address) = await* _fetchAccountAddress(accountId);
        return address;
    };
    
    /// Mint the corresponding icBTC on IC after transferring BTC to the deposit address.
    public shared(msg) func update_balance(_account : Account): async {
        #Ok : Minter.UpdateBalanceResult; // { block_index : Nat64; amount : Nat64 }
        #Err : Minter.UpdateBalanceError;
      }
      {
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("402: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        await* _initMinterAddress();
        let __start = Time.now();
        let accountId = _accountId(_account.owner, _account.subaccount);
        let account : Minter.Account = _account;
        var ownAddress : Text = "";
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#TemporarilyUnavailable("405: IC network is busy, please try again later.")); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({error_code = 400; error_message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        if (not(_dosCheck(accountId, 10)) or not(_dosCheck(_accountId(msg.caller, null), 10))){
            return #Err(#GenericError({error_code = 400; error_message = "400: The network is busy, please try again later!"}))
        };
        _setLatestVisitTime(msg.caller);
        var amount : Nat64 = 0;
        var utxos : [Utxo] = [];
        if (_isDepositUpdating(accountId)){
            return #Err(#GenericError({error_code = 400; error_message="400: You have a request in process."}));
        };
        _putDepositUpdating(accountId);
        try {
            countAsyncMessage += 2;
            let res = await* _fetchAccountUtxos(?account);
            ownAddress := res.0;
            amount := res.1;
            utxos := res.2;
            _removeDepositUpdating(accountId);
            _putAddressAccount(ownAddress, account);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            _removeDepositUpdating(accountId);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return #Err(#TemporarilyUnavailable(Error.message(e)))
        };
        if (utxos.size() > 0 and amount > Nat64.fromNat(ckFixedFee)){
            // mint icBTC
            let fixedFee = Nat64.fromNat(ckFixedFee);
            let value = Nat64.sub(amount, fixedFee);
            let saga = _getSaga();
            let toid = _mintIcToken(null, account, ownAddress, value, null);
            // mint Fee 
            _addFeeBalance(fixedFee);
            let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
            if (fixedFee > 0){
                ignore _mintIcToken(?toid, feetoAccount, "", fixedFee, ?"mint_fee");
            };
            saga.close(toid);
            totalBtcFee += fixedFee;
            totalBtcReceiving += value;
            // record event
            let event : Minter.Event = #received_utxos({to_account  = account; deposit_address = ownAddress; total_fee = Nat64.toNat(fixedFee); amount = Nat64.toNat(value); utxos = _toUtxosArr(utxos) });
            let thisBlockIndex = _putEvent(event, ?_accountId(account.owner, account.subaccount));
            lastExecutionDuration := Time.now() - __start;
            if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
            // let sagaRes = await saga.run(toid);
            if (toid > 0 and _asyncMessageSize() < 360){ 
                lastSagaRunningTime := Time.now();
                await* _ictcSagaRun(toid, false);
            }; 
            return #Ok({ block_index = Nat64.fromNat(thisBlockIndex); amount = value });
        }else if (utxos.size() > 0 and amount <= Nat64.fromNat(ckFixedFee)){
            return #Err(#GenericError({ error_message = "Amount below "# Nat.toText(ckFixedFee) #" will be ignored (discarded)"; error_code = 418 }));
        }else{
            return #Err(#NoNewUtxos);
        };
    };
    
    /// Gets the withdrawal address of icBTC. 
    /// Note: It is a query method, so you need to pay attention to its security.
    public query func get_withdrawal_account(_account : Account) : async Minter.Account{
        let accountId = _accountId(_account.owner, _account.subaccount);
        return {owner=Principal.fromActor(this); subaccount=?Blob.toArray(accountId)};
    };

    /// Provide BTC address and retrieve the native BTC.
    public shared(msg) func retrieve_btc(args: Minter.RetrieveBtcArgs, _sa: ?Sa) : async {
        #Ok : Minter.RetrieveBtcOk; //{ block_index : Nat64 };
        #Err : Minter.RetrieveBtcError;
      }{
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("402: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        if (Array.size(txInProcess) > 50){
            return #Err(#GenericError({error_code = 401; error_message = "401: Too many transactions waiting to be processed, please try again later."}))
        };
        let accountId = _accountId(msg.caller, _sa);
        let account : Minter.Account = { owner = msg.caller; subaccount = _sa; };
        let retrieveAccount : Minter.Account = { owner = Principal.fromActor(this); subaccount = ?Blob.toArray(accountId); };
        let retrieveIcrc1Account: ICRC1.Account = {owner = Principal.fromActor(this); subaccount = ?accountId};
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#TemporarilyUnavailable("405: IC network is busy, please try again later.")); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({error_code = 400; error_message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        if (not(_dosCheck(accountId, 10)) or not(_dosCheck(_accountId(msg.caller, null), 10))){
            return #Err(#GenericError({error_code = 400; error_message = "400: The network is busy, please try again later!"}))
        };
        _setLatestVisitTime(msg.caller);
        //update fee
        if (Time.now() > lastUpdateFeeTime + 4*3600*ns_){
            lastUpdateFeeTime := Time.now();
            btcFee := await* _getBtcFee();
            if (icBTCFee == 0){
                icBTCFee := await icBTC.icrc1_fee();
            };
        };
        let fee = Nat64.fromNat(ckFixedFee) + btcFee * AVG_TX_BYTES / 1000;
        // fetch minter_address
        await* _initMinterAddress();
        //update minter otxos
        if (args.amount + fee >= minterRemainingBalance or Time.now() > lastFetchUtxosTime + 4*3600*ns_){
            lastFetchUtxosTime := Time.now();
            ignore await* _fetchAccountUtxos(null);
        };
        //MalformedAddress
        switch(Address.scriptPubKey(#p2pkh(args.address))){
            case(#ok(pubKey)){};
            case(#err(msg)){
                return #Err(#MalformedAddress(msg));
            };
        };
        //AmountTooLow
        if (args.amount < Nat64.max(BTC_MIN_AMOUNT, fee)){
            return #Err(#AmountTooLow(Nat64.max(BTC_MIN_AMOUNT, fee)));
        };
        let balance = await icBTC.icrc1_balance_of(retrieveIcrc1Account);
        //InsufficientFunds
        if (Nat64.fromNat(balance) < args.amount){
            return #Err(#InsufficientFunds({balance = Nat64.fromNat(balance)}));
        };
        //Insufficient BTC available
        if (args.amount > minterRemainingBalance){
            return #Err(#TemporarilyUnavailable("Please try again later as some BTC balance of the smart contract is in unconfirmed status."));
        };
        //burn
        switch(await* _burnCkTokenWithoutIctc(accountId, args.address, args.amount, account)){
            case(#Ok(height)){
                let value = Nat64.sub(args.amount, fee); // Satoshi
                totalBtcFee += fee;
                totalBtcSent += args.amount;
                let thisTxIndex = txIndex;
                let status : Minter.RetrieveStatus = {
                    account = account;
                    retrieveAccount = retrieveAccount;
                    burnedBlockIndex = height;
                    btcAddress = args.address;
                    amount = value;
                    txIndex = thisTxIndex;
                };
                // mint Fee
                _addFeeBalance(fee);
                let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
                let toid = _mintIcToken(null, feetoAccount, "", fee, ?"mint_fee");
                _getSaga().close(toid);
                // record event
                let event : Minter.Event = #accepted_retrieve_btc_request({
                    txi = thisTxIndex;
                    account = account;
                    icrc1_burned_txid = height;
                    address = args.address;
                    amount = value;
                    total_fee = Nat64.toNat(fee);
                });
                let thisBlockIndex = _putEvent(event, ?_accountId(account.owner, account.subaccount));
                retrieveBTC := Trie.put(retrieveBTC, keyn(thisBlockIndex), Nat.equal, status).0;
                _pushSendingBtc(thisTxIndex, Nat64.fromNat(thisBlockIndex), args.address, value);
                if (Time.now() > lastTxTime + SEND_TXN_INTERVAL * ns_){ // Batch send. 
                    lastTxTime := Time.now();
                    txIndex += 1;
                    await* _sendBtc(?thisTxIndex);
                };
                return #Ok({block_index = Nat64.fromNat(thisBlockIndex) });
            };
            case(#Err(#InsufficientFunds({ balance }))){
                return #Err(#GenericError({ error_message="417: Insufficient balance when burning token."; error_code = 417 }));
            };
            case(_){
                return #Err(#GenericError({ error_message = "412: Error on burning icBTC"; error_code = 412 }));
            };
        };
      };
    
    /// Batch submit txns for sending BTC by coordinating chain smart contract. Note: this does not have to be called, normally the timer performs these tasks 
    /// and only needs to be called for testing or when urgently needed.
    public shared(msg) func batch_send(_txIndex: ?Nat) : async Bool{
        _checkICTCError();
        if (not(_notPaused() or _onlyOwner(msg.caller))){
            throw Error.reject("400: The system has been suspended!");
        };
        if (not(_checkCycles())){
            countRejections += 1; 
            throw Error.reject("402: The balance of canister's cycles is insufficient, increase the balance as soon as possible."); 
        };
        let txi = Option.get(_txIndex, txIndex);
        if (txi == txIndex and _isWaitingToSendBTC(_txIndex)){
            if (Time.now() > lastTxTime + SEND_TXN_INTERVAL * ns_){
                lastTxTime := Time.now();
                let thisTxIndex = txIndex;
                txIndex += 1;
                await* _sendBtc(?thisTxIndex);
                return true;
            };
        }else if (_isWaitingToSendBTC(_txIndex)){
            if (not(_checkAsyncMessageLimit())){
                countRejections += 1; 
                return false; 
            };
            if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
                return false;
            };
            _setLatestVisitTime(msg.caller);
            await* _sendBtc(_txIndex);
            return true;
        };
        return false;
    };

    /// Returns the status of the retrieval operation.
    public query func retrieve_btc_status(args: { block_index : Nat64; }) : async Minter.RetrieveBtcStatus{
        switch(Trie.get(retrieveBTC, keyn(Nat64.toNat(args.block_index)), Nat.equal)){
            case(?(item)){
                switch(Trie.get(sendingBTC, keyn(item.txIndex), Nat.equal)){
                    case(?(record)){
                        return record.status;
                    };
                    case(_){
                        return #Unknown;
                    };
                };
            };
            case(_){ return #Unknown; };
        };
    };

    /// Returns retrieval log.
    public query func retrieval_log(_blockIndex : ?Nat64) : async ?Minter.RetrieveStatus{
        let blockIndex_ = Option.get(_blockIndex, Nat64.fromNat(eventBlockIndex));
        switch(Trie.get(retrieveBTC, keyn(Nat64.toNat(blockIndex_)), Nat.equal)){
            case(?(item)){
                return ?item;
            };
            case(_){ return null; };
        };
    };

    /// Returns retrieval log list.
    public query func retrieval_log_list(_page: ?ListPage, _size: ?ListSize) : async TrieList<EventBlockHeight, Minter.RetrieveStatus>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        return ICEvents.trieItems2<Minter.RetrieveStatus>(retrieveBTC, firstBlockIndex, eventBlockIndex, page, size);
    };

    /// Returns sending btc log.
    public query func sending_log(_txIndex : ?Nat) : async ?Minter.SendingBtcStatus{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                return ?item;
            };
            case(_){ return null; };
        };
    };

    /// Returns sending btc log list.
    public query func sending_log_list(_page: ?ListPage, _size: ?ListSize) : async TrieList<TxIndex, Minter.SendingBtcStatus>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        return ICEvents.trieItems2<Minter.SendingBtcStatus>(sendingBTC, firstTxIndex, txIndex, page, size);
    };

    /// Returns utxos at the specified address.
    public query func utxos(_address: Address) : async ?(PubKey, DerivationPath, [Utxo]){
        return _getAccountUtxos(_address);
    };

    /// Returns utxos of icBTCMinter pool (vault).
    public query func vaultUtxos() : async (Nat64, [(Address, PubKey, DerivationPath, Utxo)]){
        return (minterRemainingBalance, List.toArray(List.append(minterUtxos.0, List.reverse(minterUtxos.1))));
    };

    /// Returns the current status data of icBTCMinter.
    public query func stats() : async {
        blockIndex: Nat64;
        txIndex: Nat;
        vaultRemainingBalance: Nat64; // minterRemainingBalance
        totalBtcFee: Nat64;
        feeBalance: Nat64;
        totalBtcReceiving: Nat64;
        totalBtcSent: Nat64;
        countAsyncMessage: Nat;
        countRejections : Nat;
    } {
        return {
            blockIndex = Nat64.fromNat(eventBlockIndex);
            txIndex = txIndex;
            vaultRemainingBalance = minterRemainingBalance; 
            totalBtcFee = totalBtcFee;
            feeBalance = feeBalance;
            totalBtcReceiving = totalBtcReceiving;
            totalBtcSent = totalBtcSent;
            countAsyncMessage = countAsyncMessage;
            countRejections = countRejections;
        };
    };

    /// Return information about icBTCMinter.
    public query func get_minter_info() : async {
        enDebug: Bool; // app_debug 
        btcNetwork: Network; //NETWORK
        minConfirmations: Nat32; // MIN_CONFIRMATIONS
        btcMinAmount: Nat64; // BTC_MIN_AMOUNT
        minVisitInterval: Nat; // MIN_VISIT_INTERVAL
        version: Text; // version_
        paused: Bool; // pause
        icBTC: Principal; // icBTC_
        icBTCFee: Nat; // icBTCFee
        btcFee: Nat64; // btcFee / 1000
        btcRetrieveFee: Nat64; // ckFixedFee + btcFee * AVG_TX_BYTES / 1000
        btcMintFee: Nat64; // ckFixedFee
        minter_address : Address;
    }{
        return {
            enDebug = app_debug;
            btcNetwork = NETWORK; //NETWORK
            minConfirmations = MIN_CONFIRMATIONS; // MIN_CONFIRMATIONS
            btcMinAmount = BTC_MIN_AMOUNT; // BTC_MIN_AMOUNT
            minVisitInterval = MIN_VISIT_INTERVAL; // MIN_VISIT_INTERVAL
            version = version_; // version_
            paused = pause; // pause
            icBTC = icBTC_; // icBTC_
            icBTCFee = icBTCFee; // icBTCFee
            btcFee = btcFee / 1000; // btcFee / 1000 Satoshis/Byte
            btcMintFee = Nat64.fromNat(ckFixedFee);
            btcRetrieveFee = Nat64.fromNat(ckFixedFee) + btcFee * AVG_TX_BYTES / 1000; // btcFee * AVG_TX_BYTES / 1000
            minter_address = minter_address;
        };
    };

    /// Returns icBTC token information
    public query func get_ck_tokens() : async [Minter.TokenInfo]{
        return [{
            symbol = "BTC";
            decimals = 8;
            totalSupply = ?2100000000000000;
            minAmount = Nat64.toNat(BTC_MIN_AMOUNT);
            ckSymbol = "icBTC";
            ckLedgerId = icBTC_;
            fixedFee = ckFixedFee; // Includes KYT fee, Platform Fee.
            dexPair = ckDexPair; 
            dexPrice = null; // 1 (Stashi) XXX = ? (Wei) USDT
        }];
    };

    /// Returns the capacity of the canister and stable mapping variables.
    public query func capacity() : async {
        memorySize: Nat;
        accountAddressesSize: Nat;
        accountUtxosSize: Nat;
        depositUpdatingSize: Nat;
        latestVisitTimeSize: Nat;
        retrieveBTCSize: Nat;
        sendingBTCSize: Nat;
        kytAccountAddressesSize: Nat;
        kytAddressAccountsSize: Nat;
        kytTxAccountsSize: Nat;
        icEventsSize: Nat;
        icAccountEventsSize: Nat;
        cyclesMonitorSize: Nat;
    }{
        return {
            memorySize = Prim.rts_memory_size();
            accountAddressesSize = Trie.size(accountAddresses);
            accountUtxosSize = Trie.size(accountUtxos);
            depositUpdatingSize = Trie.size(depositUpdating);
            latestVisitTimeSize = Trie.size(latestVisitTime);
            retrieveBTCSize = Trie.size(retrieveBTC);
            sendingBTCSize = Trie.size(sendingBTC);
            kytAccountAddressesSize = Trie.size(kyt_accountAddresses);
            kytAddressAccountsSize = Trie.size(kyt_addressAccounts);
            kytTxAccountsSize = Trie.size(kyt_txAccounts);
            icEventsSize = Trie.size(icEvents);
            icAccountEventsSize = Trie.size(icAccountEvents);
            cyclesMonitorSize = Trie.size(cyclesMonitor);
        };
    };

    /* ===========================
      Management section
    ============================== */

    /// Returns owner of the canister.
    public query func getOwner() : async Principal{  
        return owner;
    };

    /// Change owner.
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        ignore _putEvent(#changeOwner({newOwner = _newOwner}), ?_accountId(owner, null));
        return true;
    };

    /// Pause (true) or start (false) the canister.
    public shared(msg) func setPause(_pause: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        pause := _pause;
        if (pause){
            ignore _putEvent(#suspend({message = ?"Suspension from DAO"}), ?_accountId(owner, null));
        }else{
            ignore _putEvent(#start({message = ?"Starting from DAO"}), ?_accountId(owner, null));
        };
        return true;
    }; 

    /// Clears the event logs based on index height.
    public shared(msg) func clearEvents(_clearFrom: EventBlockHeight, _clearTo: EventBlockHeight): async (){
        assert(_onlyOwner(msg.caller));
        assert(_clearTo >= _clearFrom);
        // icEvents
        icEvents := ICEvents.clearEvents<Event>(icEvents, _clearFrom, _clearTo);
        // retrieveBTC
        for (i in Iter.range(_clearFrom, _clearTo)){
            retrieveBTC := Trie.remove(retrieveBTC, keyn(i), Nat.equal).0;
        };
        firstBlockIndex := _clearTo + 1;
    };

    /// Clears the transaction status record for sending BTC.
    public shared(msg) func clearSendingTxs(_clearFrom: TxIndex, _clearTo: TxIndex): async (){
        assert(_onlyOwner(msg.caller));
        assert(_clearTo >= _clearFrom);
        // sendingBTC
        for (i in Iter.range(_clearFrom, _clearTo)){
            sendingBTC := Trie.remove(sendingBTC, keyn(i), Nat.equal).0;
        };
        firstTxIndex := _clearTo + 1;
    };

    /// Rebalance icBTCMinter.
    ///
    /// Warning: To ensure the accuracy of the balance update, it is necessary to wait for the minimum required number of 
    /// block confirmations before calling this function after suspending the contract operation.
    public shared(msg) func updateMinterBalance(_surplusToFee: Bool) : async {pre: Minter.BalanceStats; post: Minter.BalanceStats; shortfall: Nat}{
        assert(_onlyOwner(msg.caller));
        assert(_ictcAllDone());
        await* _initMinterAddress();
        let feetoAccount = {owner = Principal.fromActor(this); subaccount = _toSaBlob(?sa_one) };
        let nativeBalance = Nat64.toNat(minterRemainingBalance);
        let ckLedger = icBTC;
        var ckTotalSupply = await ckLedger.icrc1_total_supply();
        var ckFeetoBalance = await ckLedger.icrc1_balance_of(feetoAccount);
        var minterBalance = Nat.sub(ckTotalSupply, ckFeetoBalance);
        var shortfall: Nat = 0;
        let preBalance = {nativeBalance = nativeBalance; totalSupply = ckTotalSupply; minterBalance = minterBalance; feeBalance = ckFeetoBalance};
        if (nativeBalance > ckTotalSupply and _surplusToFee){
            let value = Nat.sub(nativeBalance, ckTotalSupply);
            ckTotalSupply += value;
            ckFeetoBalance += value;
            let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
            let toid = _mintIcToken(null, feetoAccount, "", Nat64.fromNat(value), ?"mint_rebalance");
            _getSaga().close(toid);
        }else if (ckTotalSupply > nativeBalance){
            var value = Nat.sub(ckTotalSupply, nativeBalance);
            if (value > ckFeetoBalance){ 
                shortfall := Nat.sub(value, ckFeetoBalance);
                value := ckFeetoBalance;
            };
            ckTotalSupply -= value;
            ckFeetoBalance -= value;
            let feetoAccount = {owner = Principal.fromActor(this); subaccount = ?sa_one };
            let toid = _burnCkToken(null, Blob.fromArray(sa_one), "", Nat64.fromNat(value), feetoAccount, ?"burn_rebalance");
            _getSaga().close(toid);
        };
        feeBalance := Nat64.fromNat(ckFeetoBalance);
        let postBalance = {nativeBalance = nativeBalance; totalSupply = ckTotalSupply; minterBalance = minterBalance; feeBalance = ckFeetoBalance};
        let _f = _getSaga().run(0);
        return {pre = preBalance; post = postBalance; shortfall = shortfall};
    };

    /// Allocate rewards from the FEE balance.
    public shared(msg) func allocateRewards(_account: Account, _value: Nat, _sendAllBalance: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        let value = _value; 
        await* _sendFromFeeBalance(_account, Nat64.fromNat(value));
        return true;
    };

    /// For debugging.
    public shared(msg) func debug_get_utxos(_address: Address) : async ICBTC.GetUtxosResponse{
        assert(_onlyOwner(msg.caller));
        Cycles.add<system>(GET_UTXOS_COST_CYCLES);
        return await ic.bitcoin_get_utxos({
            address = _address;
            network = NETWORK;
            filter = ?#MinConfirmations(MIN_CONFIRMATIONS); 
        });
    };

    /// For debugging.
    public shared(msg) func debug_get_btc_fee(): async [Nat64]{
        assert(_onlyOwner(msg.caller));
        Cycles.add<system>(GET_CURRENT_FEE_PERCENTILES_COST_CYCLES);
        let fees = await ICBTC.get_current_fee_percentiles(NETWORK);
        return fees;
    };

    /// For debugging.
    public query func debug_sendingBTC(_txIndex : ?Nat) : async ?Text{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                let signedTx: [Nat8] = Option.get(item.signedTx, []);
                let transaction = Utils.get_ok(Transaction.fromBytes(Iter.fromArray(signedTx)));
                return ?(debug_show(transaction.id()) # " / " # debug_show(transaction.txInputs.size()) # " / " # debug_show(transaction.txOutputs.size()) # " / " # debug_show(transaction.toBytes()));
            };
            case(_){ return null; };
        };
    };

    /// For debugging.
    public shared(msg) func debug_charge_address(): async Text{
        assert(_onlyOwner(msg.caller));
        let res = await* _fetchAccountAddress(Blob.fromArray([]));
        return res.1;
    };
    
    /// For debugging.
    public shared(msg) func debug_reSendBTC(_txIndex: Nat, _fee: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        await* _reSendBtc(_txIndex, _fee);
    };

    /// For debugging.
    public shared(msg) func debug_reconciliation(): async (){
        assert(_onlyOwner(msg.caller));
        await* _reconciliation();
    };

    /* ===========================
      Token wasm section
    ============================== */
    private func _getLatestIcrc1Wasm(): (wasm: [Nat8], version: Text){
        if (icrc1WasmHistory.size() == 0){ 
            return ([], ""); 
        }else{
            return icrc1WasmHistory[0];
        };
    };

    /// Sets token wasm.
    public shared(msg) func setCkTokenWasm(_wasm: Blob, _version: Text) : async (){
        assert(_onlyOwner(msg.caller));
        assert(Option.isNull(Array.find(icrc1WasmHistory, func (t: ([Nat8], Text)): Bool{ _version == t.1 })));
        icrc1WasmHistory := Tools.arrayAppend([(Blob.toArray(_wasm), _version)], icrc1WasmHistory);
        if (icrc1WasmHistory.size() > 32){
            icrc1WasmHistory := Tools.slice(icrc1WasmHistory, 0, ?31);
        };
        ignore _putEvent(#config({setting = #setTokenWasm({version=_version; size=_wasm.size()})}), ?_accountId(owner, null));
    };

    /// Gets version of token wasm.
    public query func getCkTokenWasmVersion() : async (Text, Nat){ 
        let wasm = _getLatestIcrc1Wasm();
        return (wasm.1, wasm.0.size());
    };

    /// Gets version history of token wasm.
    public query func getCkTokenWasmHistory(): async [(Text, Nat)]{
        return Array.map<([Nat8], Text), (Text, Nat)>(icrc1WasmHistory, func (t: ([Nat8], Text)): (Text, Nat){
            return (t.1, t.0.size());
        });
    };

    /// Creates wrapped token (icBTC).  
    /// args:
    /// - totalSupply: ?Nat; // Maximum supply of icBTC (satoshi) - Optional.
    /// - ckTokenFee: Nat; // The transaction fee (satoshi) for icBTC .
    /// - ckTokenName: Text; // Token name, e.g. "BTC on IC".
    /// - ckTokenSymbol: Text; // Token symbol, e.g. "icBTC".
    /// - ckTokenDecimals: Nat8; // Token decimals, e.g. "8".
    public shared(msg) func launchToken(_args: {
        totalSupply: ?Nat/*smallest_unit Token*/; 
        ckTokenFee: Nat/*smallest_unit Token*/; 
        ckTokenName: Text;
        ckTokenSymbol: Text;
        ckTokenDecimals: Nat8;
    }) : async Principal{
        assert(_onlyOwner(msg.caller));
        assert(icBTC_ == Principal.fromText("aaaaa-aa")); // uninitialised state
        let wasm = _getLatestIcrc1Wasm();
        assert(wasm.0.size() > 0);
        let ic: IC.Self = actor("aaaaa-aa");
        Cycles.add<system>(INIT_CKTOKEN_CYCLES);
        let newCanister = await ic.create_canister({ settings = ?{
            freezing_threshold = null;
            controllers = ?[Principal.fromActor(this), Principal.fromText(blackhole_)];
            memory_allocation = null;
            compute_allocation = null;
        } });
        await ic.install_code({
            arg = Blob.toArray(to_candid({ 
                totalSupply = 0; 
                decimals = _args.ckTokenDecimals; 
                fee = _args.ckTokenFee; 
                name = ?_args.ckTokenName; 
                symbol = ?_args.ckTokenSymbol; 
                metadata = null; 
                founder = null;
            }: DRC20.InitArgs, app_debug));
            wasm_module = wasm.0;
            mode = #install; // #reinstall; #upgrade; #install
            canister_id = newCanister.canister_id;
        });
        icBTC_ := newCanister.canister_id;
        icBTC := actor(Principal.toText(icBTC_));
        //Set FEE_TO & Minter
        let ictokens : ICTokens.Self = actor(Principal.toText(newCanister.canister_id));
        ignore await ictokens.ictokens_config({feeTo = ?Tools.principalToAccountHex(Principal.fromActor(this), ?sa_one)});
        ignore await ictokens.ictokens_addMinter(Principal.fromActor(this));
        cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, newCanister.canister_id);
        return newCanister.canister_id;
    };

    /// Sets logo of icBTC token.
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

    /// Upgrades icBTC token.
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

    /* ===========================
      Events section
    ============================== */
    private func _putEvent(_event: Event, _a: ?AccountId) : EventBlockHeight{
        icEvents := ICEvents.putEvent<Event>(icEvents, eventBlockIndex, _event);
        switch(_a){
            case(?(accountId)){ 
                icAccountEvents := ICEvents.putAccountEvent(icAccountEvents, firstBlockIndex, accountId, eventBlockIndex);
            };
            case(_){};
        };
        eventBlockIndex += 1;
        return Nat.sub(eventBlockIndex, 1);
    };
    ignore _putEvent(#initOrUpgrade({initArgs = initArgs}), ?_accountId(owner, null));

    /// Returns an event log.
    public query func get_event(_blockIndex: EventBlockHeight) : async ?(Event, Timestamp){
        return ICEvents.getEvent(icEvents, _blockIndex);
    };

    /// Returns the first index of events that exists in the canister.
    public query func get_event_first_index() : async EventBlockHeight{
        return firstBlockIndex;
    };

    /// Returns event log list.
    public query func get_events(_page: ?ListPage, _size: ?ListSize) : async TrieList<EventBlockHeight, (Event, Timestamp)>{
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        return ICEvents.trieItems2<(Event, Timestamp)>(icEvents, firstBlockIndex, eventBlockIndex, page, size);
    };

    /// Returns event logs for the specified account.
    public query func get_account_events(_accountId: AccountId) : async [(Event, Timestamp)]{ //latest 1000 records
        return ICEvents.getAccountEvents<Event>(icEvents, icAccountEvents, _accountId);
    };

    /// Returns the number of specified account's events.
    public query func get_event_count() : async Nat{
        return eventBlockIndex;
    };

    /* ===========================
      KYT section
      Instead of using blacklists, whitelists, and auditing mechanisms, a method of providing on-chain data transparency 
      was used to deal with money laundering.
    ============================== */
    private let chainName = "Bitcoin";
    private func _putAddressAccount(_address: KYT.Address, _account: KYT.Account) : (){
        if (Principal.isController(_account.owner)){
            return ();
        };
        let tokenBlob = Blob.fromArray([]);
        let res = KYT.putAddressAccount(kyt_accountAddresses, kyt_addressAccounts, (chainName, tokenBlob, _address), (icBTC_, _account));
        kyt_accountAddresses := res.0;
        kyt_addressAccounts := res.1;
    };
    private func _getAccountAddress(_accountId: KYT.AccountId) : ?[KYT.ChainAccount]{
        return KYT.getAccountAddress(kyt_accountAddresses, _accountId);
    };
    private func _getAddressAccount(_address: KYT.Address) : ?[KYT.ICAccount]{
        return KYT.getAddressAccount(kyt_addressAccounts, _address);
    };
    private func _putTxAccount(_txHash: KYT.TxHash, _address: KYT.Address, _account: KYT.Account) : (){
        if (Principal.isController(_account.owner)){
            return ();
        };
        let tokenBlob = Blob.fromArray([]);
        kyt_txAccounts := KYT.putTxAccount(kyt_txAccounts, _txHash, (chainName, tokenBlob, _address), (icBTC_, _account));
    };
    private func _getTxAccount(_txHash: KYT.TxHash) : ?[(KYT.ChainAccount, KYT.ICAccount)]{
        return KYT.getTxAccount(kyt_txAccounts, _txHash);
    };

    /// Query the address of the relevant bitcoin chain by the IC's account-id.
    public query func get_cached_address(_accountId : KYT.AccountId) : async ?[KYT.ChainAccount]{
        return _getAccountAddress(_accountId);
    };

    /// Query the IC's account-id by the address of the bitcoin chain.
    public query func get_cached_account(_address : KYT.Address) : async ?[KYT.ICAccount]{
        return _getAddressAccount(_address);
    };

    /// Query the IC's account-id by the txid of the bitcoin chain.
    public query func get_cached_tx_account(_txHash: KYT.TxHash) : async ?[(KYT.ChainAccount, KYT.ICAccount)]{
        return _getTxAccount(_txHash);
    };

    /* ===========================
     Cycles monitor
    ============================== */

    /// Put a canister-id into the monitor.
    public shared(msg) func monitor_put(_canisterId: Principal): async (){
        assert(_onlyOwner(msg.caller));
        cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, _canisterId);
    };

    /// Remove a canister-id from the monitor.
    public shared(msg) func monitor_remove(_canisterId: Principal): async (){
        assert(_onlyOwner(msg.caller));
        cyclesMonitor := CyclesMonitor.remove(cyclesMonitor, _canisterId);
    };

    /// Returns all canister-ids in the monitor.
    public query func monitor_canisters(): async [(Principal, Nat)]{
        return Iter.toArray(Trie.iter(cyclesMonitor));
    };


    /**
    * ICTC Transaction Explorer Interface
    * (Optional) Implement the following interface, which allows you to browse transaction records and execute compensation transactions through a UI interface.
    * https://cmqwp-uiaaa-aaaaj-aihzq-cai.raw.ic0.app/
    */
    // TO = Transaction Order, which contain one or more TTs.
    // TT = Transaction Task.
    private stable var ictc_admins: [Principal] = [];
    private func _onlyIctcAdmin(_caller: Principal) : Bool { 
        return Option.isSome(Array.find(ictc_admins, func (t: Principal): Bool{ t == _caller }));
    }; 
    private func _onlyBlocking(_toid: Nat) : Bool{
        // Saga
        switch(_getSaga().status(_toid)){
            case(?(status)){ return status == #Blocking };
            case(_){ return false; };
        };
    };

    /// Returns to ICTC administrators
    public query func ictc_getAdmins() : async [Principal]{
        return ictc_admins;
    };

    /// Add an ICTC administrator.
    public shared(msg) func ictc_addAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller)); // or _onlyIctcAdmin(msg.caller)
        if (Option.isNull(Array.find(ictc_admins, func (t: Principal): Bool{ t == _admin }))){
            ictc_admins := Tools.arrayAppend(ictc_admins, [_admin]);
        };
    };

    /// Remove an ICTC administrator.
    public shared(msg) func ictc_removeAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller)); // or _onlyIctcAdmin(msg.caller)
        ictc_admins := Array.filter(ictc_admins, func (t: Principal): Bool{ t != _admin });
    };

    /// Returns ICTC TM type.
    public query func ictc_TM() : async Text{
        return "Saga";
    };

    /// Returns ICTC TO number.
    public query func ictc_getTOCount() : async Nat{
        return _getSaga().count();
    };

    /// Returns an ICTC TO.
    public query func ictc_getTO(_toid: SagaTM.Toid) : async ?SagaTM.Order<CustomCallType>{
        return _getSaga().getOrder(_toid);
    };

    /// Returns ICTC TOs.
    public query func ictc_getTOs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Toid, SagaTM.Order<CustomCallType>)]; totalPage: Nat; total: Nat}{
        return _getSaga().getOrders(_page, _size);
    };

    /// Returns an ICTC TO pool in process.
    public query func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order<CustomCallType>)]{
        return _getSaga().getAliveOrders();
    };

    /// Returns an ICTC TT.
    public query func ictc_getTT(_ttid: SagaTM.Ttid) : async ?SagaTM.TaskEvent<CustomCallType>{
        return _getSaga().getActuator().getTaskEvent(_ttid);
    };

    /// Returns ICTC TTs according to the specified TO.
    public query func ictc_getTTByTO(_toid: SagaTM.Toid) : async [SagaTM.TaskEvent<CustomCallType>]{
        return _getSaga().getTaskEvents(_toid);
    };

    /// Returns ICTC TTs.
    public query func ictc_getTTs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Ttid, SagaTM.TaskEvent<CustomCallType>)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getTaskEvents(_page, _size);
    };

    /// Returns an ICTC TT pool in process.
    public query func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task<CustomCallType>)]{
        let pool = _getSaga().getActuator().getTaskPool();
        let arr = Array.map<(SagaTM.Ttid, SagaTM.Task<CustomCallType>), (SagaTM.Ttid, SagaTM.Task<CustomCallType>)>(pool, 
        func (item:(SagaTM.Ttid, SagaTM.Task<CustomCallType>)): (SagaTM.Ttid, SagaTM.Task<CustomCallType>){
            (item.0, item.1);
        });
        return arr;
    };

    /// Returns the TTs that were in error.
    public query func ictc_getTTErrors(_page: Nat, _size: Nat) : async {data: [(Nat, SagaTM.ErrorLog)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getErrorLogs(_page, _size);
    };

    /// Returns a callee's status.
    public query func ictc_getCalleeStatus(_callee: Principal) : async ?SagaTM.CalleeStatus{
        return _getSaga().getActuator().calleeStatus(_callee);
    };

    /// Clears the ICTC logs.
    public shared(msg) func ictc_clearLog(_expiration: ?Int, _delForced: Bool) : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().clear(_expiration, _delForced);
    };

    /// Clears TT pool in process.
    public shared(msg) func ictc_clearTTPool() : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().getActuator().clearTasks();
    };

    /// Blocks a TO.
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

    /// Appends a TT to blocking TO.
    public shared(msg) func ictc_appendTT(_businessId: ?Blob, _toid: SagaTM.Toid, _forTtid: ?SagaTM.Ttid, _callee: Principal, _callType: SagaTM.CallType<CustomCallType>, _preTtids: [SagaTM.Ttid]) : async SagaTM.Ttid{
        // Governance or manual compensation (operation allowed only when a transaction order is in blocking status).
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.open(_toid);
        let taskRequest = _buildTask(_businessId, _callee, _callType, _preTtids, GET_UTXOS_COST_CYCLES, null, null);
        //let ttid = saga.append(_toid, taskRequest, null, null);
        let ttid = saga.appendComp(_toid, Option.get(_forTtid, 0), taskRequest, null);
        return ttid;
    };

    /// Try the TT again.
    public shared(msg) func ictc_redoTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        let ttid = saga.redo(_toid, _ttid);
        await* _ictcSagaRun(_toid, true);
        return ttid;
    };

    /// Skips a TT, and set status.
    public shared(msg) func ictc_doneTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid, _toCallback: Bool) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        try{
            countAsyncMessage += 2;
            let ttid = await* saga.taskDone(_toid, _ttid, _toCallback);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return ttid;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };

    /// Skips a TO, and set status.
    public shared(msg) func ictc_doneTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _toCallback: Bool) : async Bool{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let res = await* saga.done(_toid, _status, _toCallback);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return res;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };

    /// Complete a TO.
    public shared(msg) func ictc_completeTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus) : async Bool{
        // After governance or manual compensations, this method needs to be called to complete the transaction order.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.close(_toid);
        await* _ictcSagaRun(_toid, true);
        try{
            countAsyncMessage += 2;
            let r = await* _getSaga().complete(_toid, _status);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };

    /// Runs ICTC and updates the status of the specified TO.
    public shared(msg) func ictc_runTO(_toid: SagaTM.Toid) : async ?SagaTM.OrderStatus{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let r = await saga.run(_toid);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };

    /// Runs ICTC.
    public shared(msg) func ictc_runTT() : async Bool{ 
        // There is no need to call it normally, but can be called if you want to execute tasks in time when a TO is in the Doing state.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller) or _notPaused());
        if (not(_checkAsyncMessageLimit())){
            throw Error.reject("405: IC network is busy, please try again later."); 
        };
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
    // Default blackhole canister: 7hdtw-jqaaa-aaaak-aaccq-cai
    // ModuleHash(dfx: 0.8.4): 603692eda4a0c322caccaff93cf4a21dc44aebad6d71b40ecefebef89e55f3be
    // Github: https://github.com/iclighthouse/ICMonitor/blob/main/Blackhole.mo

    /// Returns the monitorability configuration of the canister.
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };

    /// Receives cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let _accepted = Cycles.accept<system>(amout);
    };

    // /// Withdraw cycles
    // public shared(msg) func withdraw_cycles(_amount: Nat, _to: Principal) : async (){
    //     assert(_onlyOwner(msg.caller));
    //     type Wallet = actor{ wallet_receive : shared () -> async (); };
    //     let wallet : Wallet = actor(Principal.toText(_to));
    //     let amount = Cycles.balance();
    //     assert(_amount + 20_000_000_000 < amount);
    //     Cycles.add<system>(_amount);
    //     await wallet.wallet_receive();
    // };

    /* ===========================
      Timer section
    ============================== */
    private func timerLoop() : async (){
        if (_now() > lastMonitorTime + 24 * 3600){
            if (Trie.size(cyclesMonitor) == 0){
                cyclesMonitor := await* CyclesMonitor.put(cyclesMonitor, icBTC_);
            };
            let monitor = await* CyclesMonitor.monitor(Principal.fromActor(this), cyclesMonitor, 1000000000000 / (if (app_debug) {2} else {1}), 1000000000000 * 10, 0);
            if (Trie.size(cyclesMonitor) == Trie.size(monitor)){
                cyclesMonitor := monitor;
            };
            lastMonitorTime := _now();
        };
        try{ await* _sendTxs(); }catch(e){};
        try{ await* _reconciliation(); }catch(e){};
    };
    private var timerId: Nat = 0;

    /// Start the Timer, it will be started automatically when upgrading the canister.
    public shared(msg) func timerStart(_intervalSeconds: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        timerId := Timer.recurringTimer<system>(#seconds(_intervalSeconds), timerLoop);
    };

    /// Stop the Timer
    public shared(msg) func timerStop(): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
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
    };
    system func postupgrade() {
        switch(__sagaDataNew){
            case(?(data)){
                _getSaga().setData(data);
                __sagaDataNew := null;
            };
            case(_){};
        };
        timerId := Timer.recurringTimer<system>(#seconds(3600*24), timerLoop);
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

    // type Toid = SagaTM.Toid;
    // type Ttid = SagaTM.Ttid;
    type Order = SagaTM.Order<CustomCallType>;
    type Task = SagaTM.Task<CustomCallType>;
    type SagaData = Backup.SagaData<CustomCallType>;
    type BackupRequest = Backup.BackupRequest;
    type BackupResponse = Backup.BackupResponse;

    /// Backs up data of the specified `BackupRequest` classification, and the result is wrapped using the `BackupResponse` type.
    public shared(msg) func backup(_request: BackupRequest) : async BackupResponse{
        assert(_onlyOwner(msg.caller));
        switch(_request){
            case(#otherData){
                return #otherData({
                    minterRemainingBalance = minterRemainingBalance;
                    totalBtcFee = totalBtcFee;
                    totalBtcReceiving = totalBtcReceiving;
                    totalBtcSent = totalBtcSent;
                    feeBalance = feeBalance;
                    txInProcess = txInProcess;
                    txIndex = txIndex;
                    firstTxIndex = firstTxIndex;
                    eventBlockIndex = eventBlockIndex;
                    firstBlockIndex = firstBlockIndex;
                    ictc_admins = ictc_admins;
                });
            };
            case(#minterUtxos){
                return #minterUtxos(List.toArray(minterUtxos.0), List.toArray(minterUtxos.1));
            };
            case(#accountUtxos){
                return #accountUtxos(Trie.toArray<Address, (PubKey, DerivationPath, [Utxo]), (Address, (PubKey, DerivationPath, [Utxo]))>(accountUtxos, 
                    func (k: Address, v: (PubKey, DerivationPath, [Utxo])): (Address, (PubKey, DerivationPath, [Utxo])){
                        let utxos: [Utxo] = (if (v.2.size() > 0){ [v.2[0]] }else{ [] });
                        return (k, (v.0, v.1, utxos));
                    }));
            };
            case(#retrieveBTC){
                return #retrieveBTC(Trie.toArray<EventBlockHeight, Minter.RetrieveStatus, (EventBlockHeight, Minter.RetrieveStatus)>(retrieveBTC, 
                    func (k: EventBlockHeight, v: Minter.RetrieveStatus): (EventBlockHeight, Minter.RetrieveStatus){
                        return (k, v);
                    }));
            };
            case(#sendingBTC){
                return #sendingBTC(Trie.toArray<TxIndex, Minter.SendingBtcStatus, (TxIndex, Minter.SendingBtcStatus)>(sendingBTC, 
                    func (k: TxIndex, v: Minter.SendingBtcStatus): (TxIndex, Minter.SendingBtcStatus){
                        return (k, v);
                    }));
            };
            case(#icrc1WasmHistory){
                let icrc1Wasm: [(wasm: [Nat8], version: Text)] = (if (icrc1WasmHistory.size() > 0){ [icrc1WasmHistory[0]] }else{ [] });
                return #icrc1WasmHistory(icrc1Wasm);
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
            case(#icEvents){
                return #icEvents(Trie.toArray<Minter.BlockHeight, (Minter.Event, Timestamp), (Minter.BlockHeight, (Minter.Event, Timestamp))>(icEvents, 
                    func (k: Minter.BlockHeight, v: (Minter.Event, Timestamp)): (Minter.BlockHeight, (Minter.Event, Timestamp)){
                        return (k, v);
                    }));
            };
            case(#icAccountEvents){
                return #icAccountEvents(Trie.toArray<AccountId, List.List<Minter.BlockHeight>, (AccountId, [Minter.BlockHeight])>(icAccountEvents, 
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
        };
    };

    /// Restore `BackupResponse` data to the canister's global variable.
    public shared(msg) func recovery(_request: BackupResponse) : async Bool{
        assert(_onlyOwner(msg.caller));
        switch(_request){
            case(#otherData(data)){
                minterRemainingBalance := data.minterRemainingBalance;
                totalBtcFee := data.totalBtcFee;
                totalBtcReceiving := data.totalBtcReceiving;
                totalBtcSent := data.totalBtcSent;
                feeBalance := data.feeBalance;
                txInProcess := data.txInProcess;
                txIndex := data.txIndex;
                firstTxIndex := data.firstTxIndex;
                eventBlockIndex := data.eventBlockIndex;
                firstBlockIndex := data.firstBlockIndex;
                ictc_admins := data.ictc_admins;
            };
            case(#minterUtxos(data)){
                minterUtxos := (List.fromArray(data.0), List.fromArray(data.1));
            };
            case(#accountUtxos(data)){
                for ((k, v) in data.vals()){
                    accountUtxos := Trie.put(accountUtxos, keyt(k), Text.equal, v).0;
                };
            };
            case(#retrieveBTC(data)){
                for ((k, v) in data.vals()){
                    retrieveBTC := Trie.put(retrieveBTC, keyn(k), Nat.equal, v).0;
                };
            };
            case(#sendingBTC(data)){
                for ((k, v) in data.vals()){
                    sendingBTC := Trie.put(sendingBTC, keyn(k), Nat.equal, v).0;
                };
            };
            case(#icrc1WasmHistory(data)){
                icrc1WasmHistory := data;
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
            case(#icEvents(data)){
                for ((k, v) in data.vals()){
                    icEvents := Trie.put(icEvents, keyn(k), Nat.equal, v).0;
                };
            };
            case(#icAccountEvents(data)){
                for ((k, v) in data.vals()){
                    icAccountEvents := Trie.put(icAccountEvents, keyb(k), Blob.equal, List.fromArray(v)).0;
                };
            };
            case(#cyclesMonitor(data)){
                for ((k, v) in data.vals()){
                    cyclesMonitor := Trie.put(cyclesMonitor, keyp(k), Principal.equal, v).0;
                };
            };
        };
        return true;
    };

};