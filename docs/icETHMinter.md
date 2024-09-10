# icETHMinter
* Module     : icETH Minter
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/

## Overview

The integration of ethereum on the IC network without bridges is achieved through chain-key (threshold signature) 
technology for ECDSA signatures, and the smart contracts of IC can directly access the RPC nodes of ethereum through 
HTTPS Outcall technology. This is the technical solution implemented in stage 1, which can be decentralized by 
configuring multiple RPC API providers. 

The user sends an ethereum asset, ETH or ERC20 token, to an address controlled by the IC smart contract (Minter), 
which receives the ethereum asset and mint icETH or icERC20 token on the IC network at a 1:1 ratio. When users want 
to retrieve the real ethereum asset, they only need to return icETH or icERC20 token to Minter smart contract to 
retrieve the ethereum assets.

icRouter's ethMinter Canister enables communication with the external chain network by calling the chain-key interface 
of the IC network, which has a dedicated subnet to provide block data and threshold ECDSA signatures, and to provide 
consensus.

## Concepts

### TSS and chain-key

Threshold Signature Scheme (TSS) is a multi-signature scheme that does not require the exposure of private keys and is well 
suited for 100% chain implementation of cross-chain transactions, which is also referred to as chain-key technology on IC.

### External Chain and Coordinating chain

External Chain is a blockchain that integrates with IC network, such as ethereum network.  
Coordinating chain is the blockchain where decentralised cross-chain smart contracts are located, in this case IC.

### Original token and Wrapped token

Original tokens are tokens issued on external chain, such as ETH.  
Wrapped tokens are tokens that have been wrapped by a smart contract with a 1:1 correspondence and issued on IC, such as icETH.

## How it works

### Minting and Retrieval

Minting is the process of locking the original tokens of external chain into the Minter contract of the coordinating chain 
and issuing the corresponding wrapped tokens. Retrieval is burning the wrapped tokens and sending the corresponding original 
tokens in the Minter contract to the holder.

### Minting: ETH/ERC20 -> icETH/icERC20 (Method 1)

Method 1 Cross-chaining original tokens to the IC network requires three steps:
- (1) The user calls get_deposit_address() method of ethMinter to get the deposit address of external chain, which is different 
for each user. It has no plaintext private key and is decentrally controlled by a subnet of the IC using TSS technology.
- (2) The user sends original tokens in his/her wallet to the above deposit address.
- (3) After waiting for external chain transaction confirmation, the user calls update_balance() method of ethMinter to mint the 
corresponding wrapped tokens in IC network. Original tokens are controlled by the ethMinter canister, and the 1:1 corresponding 
wrapped tokens are ICRC1 tokens on the IC network.

### Minting: ETH/ERC20 -> icETH/icERC20 (Method 2)

Method 2 Cross-chaining original tokens to the IC network requires three steps:
- (1) The user sends original tokens to the ethMinter pool address, which is controlled by the ethMinter but does not 
have a plaintext private key and is decentrally controlled by a subnet of the IC using TSS technology.
- (2) The user signs an EIP712 signature in his wallet, which includes the above icRouter label, txid, the user's principal 
in IC.
- (3) The user calls ethMinter's claim() method, providing the txid and signature. ethMinter mints the corresponding 
wrapped tokens on IC after checking the parameters and blockchain data.

### Retrieval: icETH/icERC20 -> ETH/ERC20

Retrieving original tokens from the IC network requires three steps.
- (1) The user gets the withdrawal address of external chain (owner is ethMinter canister-id, subaccount is user 
account-id), or he can call ethMinter's get_withdrawal_account() method to get it (this is a query method, so 
needs to pay attention to its security).
- (2) The user sends wrapped tokens to the above withdrawal address and burns them.
- (3) The user calls ethMinter's retrieve() method to provide his/her address of external chain and retrieve the 
original tokens. In this process, the original tokens that were stored in the ethMinter canister 
are sent to the destination address using the threshold signature technique.

### RPC Whitelist and Keepers

icETHMinter sets up RPC whitelists and Keepers through governance, where Keepers submit RPC URLs. icETHMinter accesses 
data from multiple RPC endpoints through http_outcall and forms consensus.

RPC Whitelist: RPC domains that are allowed to be added to icETHMinter, generally common RPC providers in the market.

Keepers: users who are added to ethMinter by governance to provide RPC URLs, they need to select RPC providers in the 
RPC whitelist.

## Function `rpc_call_transform`
``` motoko no-repl
func rpc_call_transform(raw : IC.TransformArgs) : async IC.HttpResponsePayload
```


## Function `get_deposit_address`
``` motoko no-repl
func get_deposit_address(_account : Account) : async EthAddress
```

Public functions *
Method-1: Returns the deposit address of external chain, which is different for each user. It has no plaintext private key and is decentrally 
controlled by a dedicated subnet of the IC using TSS technology.

## Function `update_balance`
``` motoko no-repl
func update_balance(_token : ?EthAddress, _account : Account) : async {#Ok : Minter.UpdateBalanceResult; #Err : Minter.ResultError}
```

Method-1: Mint the corresponding wrapped tokens on IC after transferring original token to the deposit address.

## Function `claim`
``` motoko no-repl
func claim(_account : Account, _txHash : TxHash, _signature : [Nat8]) : async {#Ok : BlockHeight; #Err : Minter.ResultError}
```

Method-2: Claim (mint) wrapped tokens on IC by providing transaction txid on external chain and signature.

## Function `get_withdrawal_account`
``` motoko no-repl
func get_withdrawal_account(_account : Account) : async Minter.Account
```

Gets the withdrawal address of wrapped token. 
Note: It is a query method, so you need to pay attention to its security.

## Function `retrieve`
``` motoko no-repl
func retrieve(_token : ?EthAddress, _address : EthAddress, _amount : Wei, _sa : ?[Nat8]) : async {#Ok : Minter.RetrieveResult; #Err : Minter.ResultError}
```

Provide address on external chain and retrieve the original token.

## Function `cover_tx`
``` motoko no-repl
func cover_tx(_txi : TxIndex, _sa : ?[Nat8]) : async ?BlockHeight
```

Re-build transaction (in response to low gas prices, etc.)

## Function `get_minter_address`
``` motoko no-repl
func get_minter_address() : async (EthAddress, Nonce)
```

Returns external chain address of icETHMinter.

## Function `get_minter_info`
``` motoko no-repl
func get_minter_info() : async MinterInfo
```

Returns infomation of icETHMinter.

## Function `get_depositing_all`
``` motoko no-repl
func get_depositing_all(_token : {#all; #eth; #token : EthAddress}, _account : ?Account) : async [(depositingBalance : Wei, txIndex : ?TxIndex, tx : ?Minter.TxStatus)]
```

Returns the records being deposited.

## Function `get_mode2_pending_deposit_txn`
``` motoko no-repl
func get_mode2_pending_deposit_txn(_txHash : TxHash) : async ?Minter.PendingDepositTxn
```

Returns the transactions that the original token is being deposited into Minter. (For method-2).

## Function `get_mode2_pending_all`
``` motoko no-repl
func get_mode2_pending_all(_token : {#all; #eth; #token : EthAddress}, _account : ?Account) : async [(txn : Minter.DepositTxn, updatedTs : Timestamp, verified : Bool)]
```

Returns all transactions that original tokens are being deposited into Minter. (For method-2).

## Function `get_mode2_deposit_txn`
``` motoko no-repl
func get_mode2_deposit_txn(_txHash : TxHash) : async ?(DepositTxn, Timestamp)
```

Returns the transactions status for depositting. (For method-2).

## Function `get_pool_balance`
``` motoko no-repl
func get_pool_balance(_token : ?EthAddress) : async Wei
```

Returns pool balance of icETHMinter.

## Function `get_fee_balance`
``` motoko no-repl
func get_fee_balance(_token : ?EthAddress) : async Wei
```

Returns fee balance of icETHMinter.

## Function `get_tx`
``` motoko no-repl
func get_tx(_txi : TxIndex) : async ?Minter.TxStatus
```

Returns the status of a transaction submitted by coordinating chain smart contract to external chain.

## Function `get_retrieval`
``` motoko no-repl
func get_retrieval(_txi : TxIndex) : async ?Minter.RetrieveStatus
```

Returns the status of the retrieval operation.

## Function `get_retrieval_list`
``` motoko no-repl
func get_retrieval_list(_account : Account) : async [Minter.RetrieveStatus]
```

Returns retrieval log list.

## Function `get_retrieving_all`
``` motoko no-repl
func get_retrieving_all(_token : {#all; #eth; #token : EthAddress}, _account : ?Account) : async [(TxIndex, Minter.TxStatus, Timestamp)]
```

Returns retrieving status list.

## Function `get_ck_tokens`
``` motoko no-repl
func get_ck_tokens() : async [(EthAddress, TokenInfo)]
```

Returns infomation for wrapped tokens.

## Function `get_event`
``` motoko no-repl
func get_event(_blockIndex : BlockHeight) : async ?(Event, Timestamp)
```

Returns event log.

## Function `get_event_first_index`
``` motoko no-repl
func get_event_first_index() : async BlockHeight
```

Returns the first index of events that exists in the canister.

## Function `get_events`
``` motoko no-repl
func get_events(_page : ?ListPage, _size : ?ListSize) : async TrieList<BlockHeight, (Event, Timestamp)>
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

## Function `get_rpc_logs`
``` motoko no-repl
func get_rpc_logs(_page : ?ListPage, _size : ?ListSize) : async TrieList<RpcId, RpcLog>
```

Returns the log list of access to the RPC

## Function `get_rpc_log`
``` motoko no-repl
func get_rpc_log(_rpcId : RpcId) : async ?RpcLog
```

Returns the log of access to the RPC

## Function `get_rpc_requests`
``` motoko no-repl
func get_rpc_requests(_page : ?ListPage, _size : ?ListSize) : async TrieList<RpcRequestId, RpcRequestConsensus>
```

Returns request list for RPC access.

## Function `get_rpc_request`
``` motoko no-repl
func get_rpc_request(_rpcRequestId : RpcRequestId) : async ?RpcRequestConsensus
```

Returns a request for RPC access. (One RPC request calling multiple RPC accesses and form consensus)

## Function `get_rpc_request_temps`
``` motoko no-repl
func get_rpc_request_temps() : async [(RpcRequestId, (confirmationStats : [([Value], Nat)], ts : Timestamp))]
```

Returns the RPC request in the process of forming a consensus.

## Function `keeper_set_rpc`
``` motoko no-repl
func keeper_set_rpc(_act : {#remove; #put : (name : Text, url : Text, status : {#Available; #Unavailable})}, _sa : ?Sa) : async Bool
```

Keeper updates the RPC URL.

## Function `get_keepers`
``` motoko no-repl
func get_keepers() : async TrieList<AccountId, Keeper>
```

Returns list of keepers

## Function `get_rpc_providers`
``` motoko no-repl
func get_rpc_providers() : async TrieList<AccountId, RpcProvider>
```


## Function `get_cached_address`
``` motoko no-repl
func get_cached_address(_accountId : KYT.AccountId) : async ?[KYT.ChainAccount]
```

Query the address of the external chain by the IC's account-id.

## Function `get_cached_account`
``` motoko no-repl
func get_cached_account(_address : KYT.Address) : async ?[KYT.ICAccount]
```

Query the IC's account-id by the address of the external chain.

## Function `get_cached_tx_account`
``` motoko no-repl
func get_cached_tx_account(_txHash : KYT.TxHash) : async ?[(KYT.ChainAccount, KYT.ICAccount)]
```

Query the IC's account-id by the txid of the external chain.

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
func setPause(_paused : Bool) : async Bool
```

Pause (true) or start (false) the canister.

## Function `setMinConfirmations`
``` motoko no-repl
func setMinConfirmations(_minConfirmations : Nat) : async Bool
```

Sets the minimum number of confirmations of the external chain.

## Function `setMinRpcConfirmations`
``` motoko no-repl
func setMinRpcConfirmations(_minConfirmations : Nat) : async Bool
```

Sets the minimum number of confirmations required to get data from the RPC.

## Function `setDepositMethod`
``` motoko no-repl
func setDepositMethod(_depositMethod : Nat8) : async Bool
```

Sets the deposit method when Minting.

## Function `addRpcWhitelist`
``` motoko no-repl
func addRpcWhitelist(_rpcDomain : Text) : async ()
```

Adds RPC domain to the whitelist.

## Function `removeRpcWhitelist`
``` motoko no-repl
func removeRpcWhitelist(_rpcDomain : Text) : async ()
```

Removes RPC domain from the whitelist.

## Function `setKeeper`
``` motoko no-repl
func setKeeper(_account : Account, _name : ?Text, _url : ?Text, _status : {#Normal; #Disabled}) : async Bool
```

Add a Keeper.

## Function `allocateRewards`
``` motoko no-repl
func allocateRewards(_args : [{ _account : Account; _value : Wei; _sendRetainedBalance : Bool }]) : async [(Account, Bool)]
```

Allocate rewards from the FEE balance.

## Function `updateRpc`
``` motoko no-repl
func updateRpc(_account : Account, _act : {#remove; #set : {#Available; #Unavailable}}) : async Bool
```

Updates an RPC URL

## Function `sync`
``` motoko no-repl
func sync() : async (Nat, Nat, Nat, Text, Nat)
```

Synchronise the basic information of the external chain.

## Function `confirmRetrievalTx`
``` motoko no-repl
func confirmRetrievalTx(_txIndex : TxIndex) : async Bool
```

Confirms a retrieval transaction, calling it when the transaction has been confirmed but the status has not 
been updated in ethMinter canister.

## Function `rebuildAndResend`
``` motoko no-repl
func rebuildAndResend(_txi : TxIndex, _nonce : {#Remain; #Reset : { spentTxHash : TxHash }}, _refetchGasPrice : Bool, _amountSub : Wei, _autoAdjust : Bool) : async ?BlockHeight
```

Rebuilds a transaction (Create a new ICTC transaction order).   
WARNING: (1) Ensure that previous transactions have failed before rebuilding the transaction. (2) If you want to reset 
the nonce, you need to make sure that the original nonce is used by another transaction, such as a blank transaction.

## Function `rebuildAndContinue`
``` motoko no-repl
func rebuildAndContinue(_txi : TxIndex, _toid : SagaTM.Toid, _nonce : {#Remain; #Reset : { spentTxHash : TxHash }}) : async ?BlockHeight
```

Rebuilds the transaction on the original task (Add compensation tasks to the original ICTC transaction order).

## Function `resetNonce`
``` motoko no-repl
func resetNonce(_arg : {#latest; #pending}) : async Nonce
```

Resets the nonce of the transaction.  
WARNING: Don't reset nonce when the system is sending transactions normally.

## Function `sendBlankTx`
``` motoko no-repl
func sendBlankTx(_nonce : Nat) : async SagaTM.Toid
```

Sends an empty transaction in order to fill a nonce value.

## Function `updateMinterBalance`
``` motoko no-repl
func updateMinterBalance(_token : ?EthAddress, _surplusToFee : Bool) : async { pre : Minter.BalanceStats; post : Minter.BalanceStats; shortfall : Wei }
```

Updates the balances of ethMinter.  
Warning: (1) To ensure the accuracy of the balance update, it is necessary to wait for the minimum required number of 
block confirmations before calling this function after suspending the contract operation. (2) If you want to attribute 
the surplus tokens to the FEE balance, you need to make sure all claim operations for the cross-chain transactions have 
been completed.

## Function `setTokenInfo`
``` motoko no-repl
func setTokenInfo(_token : ?EthAddress, _info : TokenInfo) : async ()
```

Sets the infomation of wrapped token.  
Warning: Directly modifying token information may introduce other exceptions.

## Function `setTokenFees`
``` motoko no-repl
func setTokenFees(_token : ?EthAddress, _args : { minAmount : Wei; fixedFee : Wei; gasLimit : Nat; ethRatio : ?Wei; totalSupply : ?Nat }) : async Bool
```

Sets fee of wrapped token.  

## Function `setTokenDexPair`
``` motoko no-repl
func setTokenDexPair(_token : {#ETH : { quoteToken : EthAddress; dexPair : Principal }; #ERC20 : { tokenId : EthAddress; dexPair : Principal }}) : async Bool
```

Sets a corresponding trading pair on ICDex for the wrapped token.   
ETH & Quote tokens args: 
- quoteToken: EthAddress // Quote token contract address.
- dexPair: Principal // The canister-id of pair "NativeToken/QuoteToken".
Other tokens args: 
- tokenId: EthAddress // The token contract address.
- dexPair: Principal // The canister-id of pair "Token/QuoteToken".

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
func launchToken(_token : ?EthAddress, _rename : ?Text, _args : { totalSupply : ?Wei; minAmount : Wei; ckTokenFee : Wei; fixedFee : Wei; gasLimit : Nat; ethRatio : Wei }) : async Principal
```

Creates wrapped token (icETH/icERC20).  
args:
- token: ?EthAddress // Smart contract address for EVM token, If it is a native token, such as ETH, fill in null and default to 0x0000000000000000000000000000000000000000.
- rename: ?Text // Rename the name of the token on the IC.
- args: 
    - totalSupply: ?Wei/*smallest_unit*/; // The total supply, default is null.
    - minAmount: Wei/*smallest_unit Token*/; // Minimum number of tokens for icETHMinter operations.
    - ckTokenFee: Wei/*smallest_unit Token*/; // The floating fee charged by icETHMinter changes dynamically due to the price (ethRatio) of the token.
    - fixedFee: Wei/*smallest_unit ETH*/; // Fixed fee charged by icETHMinter.
    - gasLimit: Nat; // The blockchain network's gas limit.
    - ethRatio: Wei/*1 Gwei ETH = ? smallest_unit Token */ // The ratio of token to native token (e.g. ETH) * 1000000000.

## Function `setTokenLogo`
``` motoko no-repl
func setTokenLogo(_canisterId : Principal, _logo : Text) : async Bool
```

Sets logo of token.

## Function `upgradeToken`
``` motoko no-repl
func upgradeToken(_canisterId : Principal, _version : Text) : async (version : Text)
```

Upgrades token canister.

## Function `removeToken`
``` motoko no-repl
func removeToken(_token : ?EthAddress) : async ()
```

Removes item from token list

## Function `clearEvents`
``` motoko no-repl
func clearEvents(_clearFrom : BlockHeight, _clearTo : BlockHeight) : async ()
```

Clears the event logs based on index height.

## Function `clearRpcLogs`
``` motoko no-repl
func clearRpcLogs(_idFrom : RpcId, _idTo : RpcId) : async ()
```

Clears RPC logs based on id range.

## Function `clearRpcRequests`
``` motoko no-repl
func clearRpcRequests(_idFrom : RpcRequestId, _idTo : RpcRequestId) : async ()
```

Clears RPC request logs based on id range.

## Function `clearDepositTxns`
``` motoko no-repl
func clearDepositTxns() : async ()
```

Clears the deposit transaction logs when minting.

## Function `clearCkTransactions`
``` motoko no-repl
func clearCkTransactions() : async ()
```

Clears the records of Minter contracts sending transactions on external chains via TSS technology.

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

## Function `debug_get_rpc`
``` motoko no-repl
func debug_get_rpc(_offset : Nat) : async (keeper : AccountId, rpcUrl : Text, size : Nat)
```

Debug *

## Function `debug_outcall`
``` motoko no-repl
func debug_outcall(_rpcUrl : Text, _input : Text, _responseSize : Nat64) : async (status : Nat, body : Blob, json : Text)
```


## Function `debug_fetch_address`
``` motoko no-repl
func debug_fetch_address(_account : Account) : async (pubkey : PubKey, ethAccount : EthAccount, address : EthAddress)
```


## Function `debug_get_address`
``` motoko no-repl
func debug_get_address(_account : Account) : async (EthAddress, Nonce)
```


## Function `debug_fetch_nonce`
``` motoko no-repl
func debug_fetch_nonce(_arg : {#latest; #pending}) : async Nonce
```


## Function `debug_fetch_balance`
``` motoko no-repl
func debug_fetch_balance(_token : ?EthAddress, _address : EthAddress, _latest : Bool) : async Nat
```


## Function `debug_fetch_token_metadata`
``` motoko no-repl
func debug_fetch_token_metadata(_token : EthAddress) : async { symbol : Text; decimals : Nat8 }
```


## Function `debug_fetch_txn`
``` motoko no-repl
func debug_fetch_txn(_txHash : TxHash) : async (rpcSuccess : Bool, txn : ?Minter.TokenTxn, height : BlockHeight, confirmation : Status, txNonce : ?Nat, returns : ?[Text])
```


## Function `debug_fetch_receipt`
``` motoko no-repl
func debug_fetch_receipt(_txHash : TxHash) : async (Bool, BlockHeight, Status, ?[Text])
```


## Function `debug_get_tx`
``` motoko no-repl
func debug_get_tx(_txi : TxIndex) : async ?Minter.TxStatus
```


## Function `debug_new_tx`
``` motoko no-repl
func debug_new_tx(_type : {#Deposit; #DepositGas; #Withdraw}, _account : Account, _tokenId : ?EthAddress, _from : EthAddress, _to : EthAddress, _amount : Wei) : async TxIndex
```


## Function `debug_local_getNonce`
``` motoko no-repl
func debug_local_getNonce(_txi : TxIndex) : async { txi : Nat; address : EthAddress; nonce : Nonce }
```


## Function `debug_local_createTx`
``` motoko no-repl
func debug_local_createTx(_txi : TxIndex) : async { txi : Nat; rawTx : [Nat8]; txHash : TxHash }
```


## Function `debug_local_signTx`
``` motoko no-repl
func debug_local_signTx(_txi : TxIndex) : async ({ txi : Nat; signature : [Nat8]; rawTx : [Nat8]; txHash : TxHash })
```


## Function `debug_local_sendTx`
``` motoko no-repl
func debug_local_sendTx(_txi : TxIndex) : async { txi : Nat; result : Result.Result<TxHash, Text>; rpcId : RpcId }
```


## Function `debug_sync_tx`
``` motoko no-repl
func debug_sync_tx(_txi : TxIndex) : async ()
```


## Function `debug_sign_and_recover_msg`
``` motoko no-repl
func debug_sign_and_recover_msg(_msg : Text) : async { address : Text; msgHash : Text; signature : Text; recovered : Text }
```


## Function `debug_send_to`
``` motoko no-repl
func debug_send_to(_principal : Principal, _from : EthAddress, _to : EthAddress, _amount : Wei) : async TxIndex
```


## Function `debug_verify_sign`
``` motoko no-repl
func debug_verify_sign(_signer : EthAddress, _account : Account, _txHash : TxHash, _signature : [Nat8]) : async (Text, { r : [Nat8]; s : [Nat8]; v : Nat64 }, EthAddress)
```


## Function `debug_sha3`
``` motoko no-repl
func debug_sha3(_msg : Text) : async Text
```


## Function `debug_updateBalance`
``` motoko no-repl
func debug_updateBalance(_aid : ?AccountId) : async ()
```


## Function `debug_clearMethod2Txn`
``` motoko no-repl
func debug_clearMethod2Txn() : async ()
```


## Function `debug_updateTokenEthRatio`
``` motoko no-repl
func debug_updateTokenEthRatio() : async ()
```


## Function `debug_convertFees`
``` motoko no-repl
func debug_convertFees() : async ()
```


## Function `debug_reconciliation`
``` motoko no-repl
func debug_reconciliation() : async ()
```


## Function `debug_removeDepositingTxi`
``` motoko no-repl
func debug_removeDepositingTxi(_accountId : AccountId, _txIndex : TxIndex) : async ()
```


## Function `debug_removeRetrievingTxi`
``` motoko no-repl
func debug_removeRetrievingTxi(_txIndex : TxIndex) : async ()
```


## Function `debug_canister_status`
``` motoko no-repl
func debug_canister_status(_canisterId : Principal) : async CyclesMonitor.canister_status
```


## Function `debug_monitor`
``` motoko no-repl
func debug_monitor() : async ()
```


## Function `debug_fetchPairPrice`
``` motoko no-repl
func debug_fetchPairPrice(_pair : Principal) : async Float
```


## Function `debug_updateTokenPrice`
``` motoko no-repl
func debug_updateTokenPrice(_tokenId : EthAddress) : async ()
```


## Function `debug_removePendingDepositTxn`
``` motoko no-repl
func debug_removePendingDepositTxn(_txHash : TxHash) : async ()
```


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
func timerStart(_intervalSeconds1 : Nat, _intervalSeconds2 : Nat) : async ()
```

Start the Timer, it will be started automatically when upgrading the canister.

## Function `timerStop`
``` motoko no-repl
func timerStop() : async ()
```

Stop the Timer

## Function `backup`
``` motoko no-repl
func backup(_request : BackupRequest) : async BackupResponse<CustomCallType>
```

Backs up data of the specified `BackupRequest` classification, and the result is wrapped using the `BackupResponse` type.

## Function `recovery`
``` motoko no-repl
func recovery(_request : BackupResponse<CustomCallType>) : async Bool
```

Restore `BackupResponse` data to the canister's global variable.
