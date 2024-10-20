# icBTCMinter
* Module     : icBTC Minter
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/

## Overview

icRouter enables the integration of Bitcoin and IC network through the Threshold Signature Scheme (TSS, also known as chain-key 
technology). icBTCs are 1:1 ICRC1 tokens minted cross-chain from Bitcoin to the IC network, and you can retrieve the original BTCs 
at any time. this is all done in a bridgeless manner, and its security depends on the security of the IC network.

## Concepts

### TSS and chain-key

Threshold Signature Scheme (TSS) is a multi-signature scheme that does not require the exposure of private keys and is well 
suited for 100% chain implementation of cross-chain transactions, which is also referred to as chain-key technology on IC.

### External Chain and Coordinating chain

External Chain is a blockchain that integrates with IC network, such as bitcoin network.  
Coordinating chain is the blockchain where decentralised cross-chain smart contracts are located, in this case IC.

### Original token and Wrapped token

Original tokens are tokens issued on external chain, such as BTC.  
Wrapped tokens are tokens that have been wrapped by a smart contract with a 1:1 correspondence and issued on IC, such as icBTC.

### Minting and Retrieval

Minting is the process of locking the original tokens of an external chain into the Minter contract of the coordinating chain 
and issuing the corresponding wrapped tokens. Retrieval is burning the wrapped tokens and sending the corresponding original 
tokens in the Minter contract to the holder.

## How it works

icRouter's btcMinter Canister enables communication with the Bitcoin network by calling the chain-key interface of the IC network, 
which has a dedicated subnet to provide block data and threshold ECDSA signatures, and to provide consensus.

### Minting: BTC -> icBTC

Cross-chaining native BTC to the IC network requires three steps:
- (1) The user calls get_btc_address() method of btcMinter to get the deposit address of external chain, which is different for 
each user. It has no plaintext private key and is decentrally controlled by a dedicated subnet of the IC using TSS technology.
- (2) The user sends BTC in his/her BTC wallet to the above deposit address.
- (3) After waiting for transaction confirmation, the user calls update_balance() method of btcMinter to mint the corresponding 
icBTC in IC network. Native BTC UTXOs are controlled by the btcMinter canister, and the 1:1 corresponding icBTC are ICRC1 tokens 
on the IC network.

### Retrieval: icBTC -> BTC

Retrieving native BTC from the IC network requires three steps.
- (1) The user gets the withdrawal address of IC (owner is btcMinter canister-id, subaccount is user account-id), or he can 
call btcMinter's get_withdrawal_account() method to get it (this is a query method, so needs to pay attention to its security).
- (2) The user sends icBTC to the above withdrawal address and burns them.
- (3) The user calls btcMinter's retrieve_btc() method to provide his/her BTC address of external chain and retrieve the native BTC. 
In this process, the BTCs that were originally stored in the btcMinter canister are sent to the destination address using the 
TSS technique.

## Function `get_btc_address`
``` motoko no-repl
func get_btc_address(_account : Account) : async Text
```

Returns the deposit address, which is different for each user. It has no plaintext private key and is decentrally 
controlled by a dedicated subnet of the IC using TSS technology.

## Function `update_balance`
``` motoko no-repl
func update_balance(_account : Account) : async {#Ok : Minter.UpdateBalanceResult; #Err : Minter.UpdateBalanceError}
```

Mint the corresponding icBTC on IC after transferring BTC to the deposit address.

## Function `get_withdrawal_account`
``` motoko no-repl
func get_withdrawal_account(_account : Account) : async Minter.Account
```

Gets the withdrawal address of icBTC. 
Note: It is a query method, so you need to pay attention to its security.

## Function `retrieve_btc`
``` motoko no-repl
func retrieve_btc(args : Minter.RetrieveBtcArgs, _sa : ?Sa) : async {#Ok : Minter.RetrieveBtcOk; #Err : Minter.RetrieveBtcError}
```

Provide BTC address and retrieve the native BTC.

## Function `batch_send`
``` motoko no-repl
func batch_send(_txIndex : ?Nat) : async Bool
```

Batch submit txns for sending BTC by coordinating chain smart contract. Note: this does not have to be called, normally the timer performs these tasks 
and only needs to be called for testing or when urgently needed.

## Function `retrieve_btc_status`
``` motoko no-repl
func retrieve_btc_status(args : { block_index : Nat64 }) : async Minter.RetrieveBtcStatus
```

Returns the status of the retrieval operation.

## Function `retrieval_log`
``` motoko no-repl
func retrieval_log(_blockIndex : ?Nat64) : async ?Minter.RetrieveStatus
```

Returns retrieval log.

## Function `retrieval_log_list`
``` motoko no-repl
func retrieval_log_list(_page : ?ListPage, _size : ?ListSize) : async TrieList<EventBlockHeight, Minter.RetrieveStatus>
```

Returns retrieval log list.

## Function `sending_log`
``` motoko no-repl
func sending_log(_txIndex : ?Nat) : async ?Minter.SendingBtcStatus
```

Returns sending btc log.

## Function `sending_log_list`
``` motoko no-repl
func sending_log_list(_page : ?ListPage, _size : ?ListSize) : async TrieList<TxIndex, Minter.SendingBtcStatus>
```

Returns sending btc log list.

## Function `utxos`
``` motoko no-repl
func utxos(_address : Address) : async ?(PubKey, DerivationPath, [Utxo])
```

Returns utxos at the specified address.

## Function `vaultUtxos`
``` motoko no-repl
func vaultUtxos() : async (Nat64, [(Address, PubKey, DerivationPath, Utxo)])
```

Returns utxos of icBTCMinter pool (vault).

## Function `stats`
``` motoko no-repl
func stats() : async { blockIndex : Nat64; txIndex : Nat; vaultRemainingBalance : Nat64; totalBtcFee : Nat64; feeBalance : Nat64; totalBtcReceiving : Nat64; totalBtcSent : Nat64; countAsyncMessage : Nat; countRejections : Nat }
```

Returns the current status data of icBTCMinter.

## Function `get_minter_info`
``` motoko no-repl
func get_minter_info() : async { enDebug : Bool; btcNetwork : Network; minConfirmations : Nat32; btcMinAmount : Nat64; minVisitInterval : Nat; version : Text; paused : Bool; icBTC : Principal; icBTCFee : Nat; btcFee : Nat64; btcRetrieveFee : Nat64; btcMintFee : Nat64; minter_address : Address }
```

Return information about icBTCMinter.

## Function `get_ck_tokens`
``` motoko no-repl
func get_ck_tokens() : async [Minter.TokenInfo]
```

Returns icBTC token information

## Function `capacity`
``` motoko no-repl
func capacity() : async { memorySize : Nat; accountAddressesSize : Nat; accountUtxosSize : Nat; depositUpdatingSize : Nat; latestVisitTimeSize : Nat; retrieveBTCSize : Nat; sendingBTCSize : Nat; kytAccountAddressesSize : Nat; kytAddressAccountsSize : Nat; kytTxAccountsSize : Nat; icEventsSize : Nat; icAccountEventsSize : Nat; cyclesMonitorSize : Nat }
```

Returns the capacity of the canister and stable mapping variables.

## Function `getOwner`
``` motoko no-repl
func getOwner() : async Principal
```

Returns owner of the canister.

## Function `changeOwner`
``` motoko no-repl
func changeOwner(_newOwner : Principal) : async Bool
```

Change owner.

## Function `setPause`
``` motoko no-repl
func setPause(_pause : Bool) : async Bool
```

Pause (true) or start (false) the canister.

## Function `clearEvents`
``` motoko no-repl
func clearEvents(_clearFrom : EventBlockHeight, _clearTo : EventBlockHeight) : async ()
```

Clears the event logs based on index height.

## Function `clearSendingTxs`
``` motoko no-repl
func clearSendingTxs(_clearFrom : TxIndex, _clearTo : TxIndex) : async ()
```

Clears the transaction status record for sending BTC.

## Function `updateMinterBalance`
``` motoko no-repl
func updateMinterBalance(_surplusToFee : Bool) : async { pre : Minter.BalanceStats; post : Minter.BalanceStats; shortfall : Nat }
```

Rebalance icBTCMinter.

Warning: To ensure the accuracy of the balance update, it is necessary to wait for the minimum required number of 
block confirmations before calling this function after suspending the contract operation.

## Function `allocateRewards`
``` motoko no-repl
func allocateRewards(_account : Account, _value : Nat, _sendAllBalance : Bool) : async Bool
```

Allocate rewards from the FEE balance.

## Function `debug_get_utxos`
``` motoko no-repl
func debug_get_utxos(_address : Address) : async ICBTC.GetUtxosResponse
```

For debugging.

## Function `debug_sendingBTC`
``` motoko no-repl
func debug_sendingBTC(_txIndex : ?Nat) : async ?Text
```

For debugging.

## Function `debug_charge_address`
``` motoko no-repl
func debug_charge_address() : async Text
```

For debugging.

## Function `debug_reSendBTC`
``` motoko no-repl
func debug_reSendBTC(_txIndex : Nat, _fee : Nat) : async ()
```

For debugging.

## Function `debug_reconciliation`
``` motoko no-repl
func debug_reconciliation() : async ()
```

For debugging.

## Function `setCkTokenWasm`
``` motoko no-repl
func setCkTokenWasm(_wasm : Blob, _version : Text) : async ()
```

Sets token wasm.

## Function `getCkTokenWasmVersion`
``` motoko no-repl
func getCkTokenWasmVersion() : async (Text, Nat)
```

Gets version of token wasm.

## Function `getCkTokenWasmHistory`
``` motoko no-repl
func getCkTokenWasmHistory() : async [(Text, Nat)]
```

Gets version history of token wasm.

## Function `launchToken`
``` motoko no-repl
func launchToken(_args : { totalSupply : ?Nat; ckTokenFee : Nat; ckTokenName : Text; ckTokenSymbol : Text; ckTokenDecimals : Nat8 }) : async Principal
```

Creates wrapped token (icBTC).  
args:
- totalSupply: ?Nat; // Maximum supply of icBTC (satoshi) - Optional.
- ckTokenFee: Nat; // The transaction fee (satoshi) for icBTC .
- ckTokenName: Text; // Token name, e.g. "BTC on IC".
- ckTokenSymbol: Text; // Token symbol, e.g. "icBTC".
- ckTokenDecimals: Nat8; // Token decimals, e.g. "8".

## Function `setTokenLogo`
``` motoko no-repl
func setTokenLogo(_canisterId : Principal, _logo : Text) : async Bool
```

Sets logo of icBTC token.

## Function `upgradeToken`
``` motoko no-repl
func upgradeToken(_canisterId : Principal, _version : Text) : async (version : Text)
```

Upgrades icBTC token.

## Function `get_event`
``` motoko no-repl
func get_event(_blockIndex : EventBlockHeight) : async ?(Event, Timestamp)
```

Returns an event log.

## Function `get_event_first_index`
``` motoko no-repl
func get_event_first_index() : async EventBlockHeight
```

Returns the first index of events that exists in the canister.

## Function `get_events`
``` motoko no-repl
func get_events(_page : ?ListPage, _size : ?ListSize) : async TrieList<EventBlockHeight, (Event, Timestamp)>
```

Returns event log list.

## Function `get_account_events`
``` motoko no-repl
func get_account_events(_accountId : AccountId) : async [(Event, Timestamp)]
```

Returns event logs for the specified account.

## Function `get_event_count`
``` motoko no-repl
func get_event_count() : async Nat
```

Returns the number of specified account's events.

## Function `get_cached_address`
``` motoko no-repl
func get_cached_address(_accountId : KYT.AccountId) : async ?[KYT.ChainAccount]
```

Query the address of the relevant bitcoin chain by the IC's account-id.

## Function `get_cached_account`
``` motoko no-repl
func get_cached_account(_address : KYT.Address) : async ?[KYT.ICAccount]
```

Query the IC's account-id by the address of the bitcoin chain.

## Function `get_cached_tx_account`
``` motoko no-repl
func get_cached_tx_account(_txHash : KYT.TxHash) : async ?[(KYT.ChainAccount, KYT.ICAccount)]
```

Query the IC's account-id by the txid of the bitcoin chain.

## Function `monitor_put`
``` motoko no-repl
func monitor_put(_canisterId : Principal) : async ()
```

Put a canister-id into the monitor.

## Function `monitor_remove`
``` motoko no-repl
func monitor_remove(_canisterId : Principal) : async ()
```

Remove a canister-id from the monitor.

## Function `monitor_canisters`
``` motoko no-repl
func monitor_canisters() : async [(Principal, Nat)]
```

Returns all canister-ids in the monitor.

## Function `ictc_getAdmins`
``` motoko no-repl
func ictc_getAdmins() : async [Principal]
```

Returns to ICTC administrators

## Function `ictc_addAdmin`
``` motoko no-repl
func ictc_addAdmin(_admin : Principal) : async ()
```

Add an ICTC administrator.

## Function `ictc_removeAdmin`
``` motoko no-repl
func ictc_removeAdmin(_admin : Principal) : async ()
```

Remove an ICTC administrator.

## Function `ictc_TM`
``` motoko no-repl
func ictc_TM() : async Text
```

Returns ICTC TM type.

## Function `ictc_getTOCount`
``` motoko no-repl
func ictc_getTOCount() : async Nat
```

Returns ICTC TO number.

## Function `ictc_getTO`
``` motoko no-repl
func ictc_getTO(_toid : SagaTM.Toid) : async ?SagaTM.Order<CustomCallType>
```

Returns an ICTC TO.

## Function `ictc_getTOs`
``` motoko no-repl
func ictc_getTOs(_page : Nat, _size : Nat) : async { data : [(SagaTM.Toid, SagaTM.Order<CustomCallType>)]; totalPage : Nat; total : Nat }
```

Returns ICTC TOs.

## Function `ictc_getTOPool`
``` motoko no-repl
func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order<CustomCallType>)]
```

Returns an ICTC TO pool in process.

## Function `ictc_getTT`
``` motoko no-repl
func ictc_getTT(_ttid : SagaTM.Ttid) : async ?SagaTM.TaskEvent<CustomCallType>
```

Returns an ICTC TT.

## Function `ictc_getTTByTO`
``` motoko no-repl
func ictc_getTTByTO(_toid : SagaTM.Toid) : async [SagaTM.TaskEvent<CustomCallType>]
```

Returns ICTC TTs according to the specified TO.

## Function `ictc_getTTs`
``` motoko no-repl
func ictc_getTTs(_page : Nat, _size : Nat) : async { data : [(SagaTM.Ttid, SagaTM.TaskEvent<CustomCallType>)]; totalPage : Nat; total : Nat }
```

Returns ICTC TTs.

## Function `ictc_getTTPool`
``` motoko no-repl
func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task<CustomCallType>)]
```

Returns an ICTC TT pool in process.

## Function `ictc_getTTErrors`
``` motoko no-repl
func ictc_getTTErrors(_page : Nat, _size : Nat) : async { data : [(Nat, SagaTM.ErrorLog)]; totalPage : Nat; total : Nat }
```

Returns the TTs that were in error.

## Function `ictc_getCalleeStatus`
``` motoko no-repl
func ictc_getCalleeStatus(_callee : Principal) : async ?SagaTM.CalleeStatus
```

Returns a callee's status.

## Function `ictc_clearLog`
``` motoko no-repl
func ictc_clearLog(_expiration : ?Int, _delForced : Bool) : async ()
```

Clears the ICTC logs.

## Function `ictc_clearTTPool`
``` motoko no-repl
func ictc_clearTTPool() : async ()
```

Clears TT pool in process.

## Function `ictc_blockTO`
``` motoko no-repl
func ictc_blockTO(_toid : SagaTM.Toid) : async ?SagaTM.Toid
```

Blocks a TO.

## Function `ictc_appendTT`
``` motoko no-repl
func ictc_appendTT(_businessId : ?Blob, _toid : SagaTM.Toid, _forTtid : ?SagaTM.Ttid, _callee : Principal, _callType : SagaTM.CallType<CustomCallType>, _preTtids : [SagaTM.Ttid]) : async SagaTM.Ttid
```

Appends a TT to blocking TO.

## Function `ictc_redoTT`
``` motoko no-repl
func ictc_redoTT(_toid : SagaTM.Toid, _ttid : SagaTM.Ttid) : async ?SagaTM.Ttid
```

Try the TT again.

## Function `ictc_doneTT`
``` motoko no-repl
func ictc_doneTT(_toid : SagaTM.Toid, _ttid : SagaTM.Ttid, _toCallback : Bool) : async ?SagaTM.Ttid
```

Skips a TT, and set status.

## Function `ictc_doneTO`
``` motoko no-repl
func ictc_doneTO(_toid : SagaTM.Toid, _status : SagaTM.OrderStatus, _toCallback : Bool) : async Bool
```

Skips a TO, and set status.

## Function `ictc_completeTO`
``` motoko no-repl
func ictc_completeTO(_toid : SagaTM.Toid, _status : SagaTM.OrderStatus) : async Bool
```

Complete a TO.

## Function `ictc_runTO`
``` motoko no-repl
func ictc_runTO(_toid : SagaTM.Toid) : async ?SagaTM.OrderStatus
```

Runs ICTC and updates the status of the specified TO.

## Function `ictc_runTT`
``` motoko no-repl
func ictc_runTT() : async Bool
```

Runs ICTC.

## Function `drc207`
``` motoko no-repl
func drc207() : async DRC207.DRC207Support
```

* End: ICTC Transaction Explorer Interface
Returns the monitorability configuration of the canister.

## Function `wallet_receive`
``` motoko no-repl
func wallet_receive() : async ()
```

Receives cycles

## Function `timerStart`
``` motoko no-repl
func timerStart(_intervalSeconds : Nat) : async ()
```

Start the Timer, it will be started automatically when upgrading the canister.

## Function `timerStop`
``` motoko no-repl
func timerStop() : async ()
```

Stop the Timer

## Function `backup`
``` motoko no-repl
func backup(_request : BackupRequest) : async BackupResponse
```

Backs up data of the specified `BackupRequest` classification, and the result is wrapped using the `BackupResponse` type.

## Function `recovery`
``` motoko no-repl
func recovery(_request : BackupResponse) : async Bool
```

Restore `BackupResponse` data to the canister's global variable.
