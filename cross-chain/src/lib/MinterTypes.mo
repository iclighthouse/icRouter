import ETHUtils "ETHUtils";
import Principal "mo:base/Principal";

module {
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public type AccountId = Blob;
  public type Address = Text;
  public type EthAddress = Text;
  public type EthAccount = [Nat8];
  public type EthAccountId = Blob;
  public type EthTokenId = Blob;
  public type PubKey = [Nat8];
  public type DerivationPath = [Blob];
  public type TxHash = Text;
  public type TxHashId = Blob;
  public type Wei = Nat;
  public type Gwei = Nat;
  public type Ether = Nat;
  public type Hash = [Nat8];
  public type HashId = Blob;
  public type HexWith0x = Text;
  public type Nonce = Nat;
  public type Cycles = Nat;
  public type Timestamp = Nat; // seconds
  public type Sa = [Nat8];
  public type Txid = Blob;
  public type BlockHeight = Nat;
  public type ICRC1BlockHeight = Nat;
  public type TxIndex = Nat;
  public type RpcId = Nat;
  public type RpcRequestId = Nat;
  public type KytId = Nat;
  public type KytRequestId = Nat;
  public type ListPage = Nat;
  public type ListSize = Nat;
  public type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };
  public type Value = {#Nat: Nat; #Int: Int; #Raw: [Nat8]; #Float: Float; #Text: Text; #Bool: Bool; #Empty;};
  public type Keeper = {
    name: Text; 
    url: Text; 
    account: Account;
    status: {#Normal; #Disabled};
    balance: Nat; // ICL
  };
  public type Healthiness = {time: Timestamp; calls: Nat; errors: Nat; recentPersistentErrors: ?Nat};
  public type RpcProvider = {
    name: Text; 
    url: Text; 
    keeper: AccountId;
    status: {#Available; #Unavailable}; 
    calls: Nat; 
    errors: Nat; 
    preHealthCheck: Healthiness;
    healthCheck: Healthiness;
    latestCall: Timestamp; 
  };
  public type RpcLog = {url: Text; time: Timestamp; input: Text; result: ?Text; err: ?Text };
  public type RpcRequestStatus = {#pending; #ok: [Value]; #err: Text};
  public type RpcFetchLog = {
      id: RpcId;
      result: Text; 
      status: RpcRequestStatus;
      keeper: AccountId;
      time: Timestamp;
  };
  public type RpcRequestConsensus = {
      confirmed: Nat; //count
      status: RpcRequestStatus;
      requests: [RpcFetchLog]; 
  };
  public type Transaction = ETHUtils.Transaction;
  public type Transaction1559 = ETHUtils.Transaction1559;
  public type RetrieveStatus = {
    account: Account;
    retrieveAccount: Account;
    burnedBlockIndex: ICRC1BlockHeight;
    ethAddress: EthAddress;
    amount: Wei; 
    txIndex: TxIndex;
  };
  public type TxStatus = {
    txType: {#Deposit; #DepositGas; #Withdraw};
    tokenId: EthAddress;// ETH: 0x0000000000000000000000000000000000000000
    account: Account;
    from: EthAddress;
    to: EthAddress;
    amount: Wei;
    fee: { gasPrice: Wei; gasLimit: Nat; maxFee: Wei; };
    nonce: ?Nonce;
    toids: [Nat];
    txHash: [TxHash];
    tx: ?Transaction;
    rawTx: ?([Nat8], [Nat8]);
    signedTx: ?([Nat8], [Nat8]);
    receipt: ?Text;
    rpcRequestId: ?RpcRequestId; // RpcId/RpcRequestId
    kytRequestId: ?KytRequestId; // KytId/KytRequestId
    status: Status;
  };
  public type Status = {
    #Building;
    #Signing;
    #Sending;
    #Submitted;
    #Pending;
    #Failure;
    #Confirmed;
    #Unknown;
  };
  public type ResultError = {
    #GenericError : { message : Text; code : Nat64 };
  };
  public type UpdateBalanceResult = { 
    blockIndex : Nat; 
    amount : Wei; // ckETH
    txIndex: TxIndex;
    toid: Nat;
  };
  public type RetrieveResult = { 
    blockIndex : Nat; 
    amount : Wei; // ETH
    retrieveFee : Wei;
    txIndex: TxIndex;
    toid: Nat;
  };
  public type TokenInfo = {
    tokenId: EthAddress;
    std: {#ETH; #ERC20};
    symbol: Text;
    decimals: Nat8;
    totalSupply: ?Wei;
    minAmount: Wei;
    ckSymbol: Text;
    ckLedgerId: Principal;
    fee: {
      fixedFee: Wei; // ETH. Includes RPC & KYT fee, Platform Fee.
      gasLimit: Nat; // for example: ETH 21000; ERC20 60000
      ethRatio: Wei; // 1 Gwei Ether = ? Wei Token
    };
    dexPair: ?Principal; // XXX/USDT
    dexPrice: ?(Float, Timestamp); // 1 (Wei) XXX = ? (Wei) USDT
  };
  public type TokenTxn = {
    token: EthAddress;
    from: EthAddress;
    to: EthAddress;
    value: Wei;
  };
  public type DepositTxn = {
    txHash: TxHash;
    account: Account;
    signature: [Nat8]; 
    claimingTime: Timestamp;
    status: Status;  //#Pending; #Failure; #Confirmed; #Unknown;
    transfer: ?TokenTxn;
    confirmedTime: ?Timestamp;
    error: ?Text;
  };
  public type PendingDepositTxn = (txHash: TxHash, account: Account, signature: [Nat8], isVerified: Bool, ts: Timestamp);
  public type UpdateTxArgs = {
      fee: ?{ gasPrice: Wei; gasLimit: Nat; maxFee: Wei;};
      amount: ?Wei;
      nonce: ?Nonce;
      toids: ?[Nat];
      txHash: ?TxHash;
      tx: ?Transaction;
      rawTx: ?([Nat8], [Nat8]);
      signedTx: ?([Nat8], [Nat8]);
      receipt: ?Text;
      rpcRequestId: ?RpcRequestId;
      kytRequestId: ?KytRequestId;
      status: ?Status;
      ts: ?Timestamp;
  };
  public type BalanceStats = {nativeBalance: Wei; totalSupply: Wei; minterBalance: Wei; feeBalance: Wei};
  public type RPCResult = {#Ok: Text; #Err: Text };
  public type Event = { //Timestamp = seconds
    #init : {initArgs: InitArgs};
    #start: { message: ?Text };
    #suspend: { message: ?Text };
    #changeOwner: {newOwner: Principal};
    #config: {setting: {
      #minConfirmations: Nat; 
      #minRpcConfirmations: Nat;
      #dependents: {utilsTool: Principal};
      #depositMethod: Nat8;
      #setKeeper: {account: Account; name: Text; url: Text; status: {#Normal; #Disabled}};
      #updateRpc: {keeper: Account; operation: {#remove; #set: {#Available; #Unavailable}}};
      #setToken: {token: EthAddress; info: TokenInfo};
      #setDexPair: {token: EthAddress; dexPair: ?Principal;};
      #setTokenWasm: {version: Text; size: Nat};
      #launchToken: {token: EthAddress; symbol: Text; icTokenCanisterId: Principal};
      #upgradeTokenWasm: {symbol: Text; icTokenCanisterId: Principal; version: Text};
    }};
    #updateTokenPrice: {token: EthAddress; price: Float; ethRatio: Wei};
    #keeper: {operation: {
      #setRpc: {keeper: Account; operation: {#remove; #put: (name: Text, status: {#Available; #Unavailable})}};
    }};
    #coverTransaction: {txIndex: TxIndex; toid: Nat; account: Account; preTxid: [TxHash]; updateTx: ?UpdateTxArgs};
    #continueTransaction: {txIndex: TxIndex; toid: Nat; account: Account; preTxid: [TxHash]; updateTx: ?UpdateTxArgs};
    #depositGas: {txIndex: TxIndex; toid: Nat; account: Account; address: EthAddress; amount: Wei};
    #depositGasResult: {
      #ok: {txIndex: TxIndex; account: Account; token: EthAddress; txid: [TxHash]; amount: Wei}; 
      #err: {txIndex: TxIndex; account: Account; token: EthAddress; amount: Wei}
    };
    #deposit: {txIndex: TxIndex; toid: Nat; account: Account; address: EthAddress; token: EthAddress; amount: Wei; fee: ?Wei};
    #depositResult: {
      #ok: {txIndex: TxIndex; account: Account; token: EthAddress; txid: [TxHash]; amount: Wei; fee: ?Wei}; 
      #err: {txIndex: TxIndex; account: Account; token: EthAddress; txid: [TxHash]; amount: Wei}
    };
    #claimDeposit: {account: Account; txHash: TxHash; signature: Text };
    #claimDepositResult: {
      #ok: {token: EthAddress; account: Account; from: EthAddress; amount: Wei; fee: ?Wei; txHash: TxHash; signature: Text }; 
      #err: {account: Account; txHash: TxHash; signature: Text; error: Text}
    };
    #mint: {toid: Nat; account: Account; icTokenCanisterId: Principal; amount: Wei};
    #withdraw: {txIndex: TxIndex; toid: Nat; account: Account; address: EthAddress; token: EthAddress; amount: Wei; fee: ?Wei};
    #withdrawResult: {
      #ok: {txIndex: TxIndex; account: Account; token: EthAddress; txid: [TxHash]; amount: Wei}; 
      #err: {txIndex: TxIndex; account: Account; token: EthAddress; txid: [TxHash]; amount: Wei}
    };
    #burn: {toid: ?Nat; account: Account; address: EthAddress; icTokenCanisterId: Principal; tokenBlockIndex: Nat; amount: Wei};
    #send: {toid: ?Nat; to: Account; icTokenCanisterId: Principal; amount: Wei};
  };

  public type InitArgs = {
    min_confirmations: ?Nat;
    rpc_confirmations: Nat;
    // rpc_canister_id: Principal;
    utils_canister_id: Principal;
    deposit_method: Nat8; // 1=Method 1; 2=Method 2; 3=All
  };
  public type MinterInfo = {
      address: EthAddress;
      isDebug: Bool;
      version: Text;
      paused: Bool;
      owner: Principal;
      minConfirmations: Nat;
      minRpcConfirmations: Nat;
      depositMethod: Nat8;
      chainId: Nat;
      network: Text;
      symbol: Text;
      decimals: Nat8;
      blockSlot: Nat;
      syncBlockNumber: BlockHeight;
      gasPrice: Wei;
      pendingDeposits: Nat;
      pendingRetrievals: Nat;
      countMinting : Nat;
      totalMintingAmount : Wei; // USD
      countRetrieval : Nat;
      totalRetrievalAmount : Wei; // USD
  };
  public type Self = actor {
      get_deposit_address : shared (_account : Account) -> async EthAddress;
      update_balance : shared (_token: ?EthAddress, _account : Account) -> async {
        #Ok : UpdateBalanceResult; 
        #Err : ResultError;
      };
      claim : shared (_account : Account, _txHash: TxHash, _signature: [Nat8]) -> async {
        #Ok : BlockHeight; 
        #Err : ResultError;
      };
      update_claims : shared () -> async ();
      get_withdrawal_account : shared query (_account : Account) -> async Account;
      retrieve : shared (_token: ?EthAddress, _address: EthAddress, _amount: Wei, _sa: ?[Nat8]) -> async { 
        #Ok : RetrieveResult; 
        #Err : ResultError;
      };
      update_retrievals : shared () -> async (sending: [(TxStatus, Timestamp)]);
      cover_tx : shared (_txi: TxIndex, _sa: ?[Nat8]) -> async ?BlockHeight;
      
      get_minter_address : shared query () -> async (EthAddress, Nonce);
      get_minter_info : shared query () -> async MinterInfo;
      get_depositing : shared query (_token: ?EthAddress, _account : Account) -> async (Wei, ?TxIndex);
      get_mode2_pending_deposit_txn : shared query (_txHash: TxHash) -> async ?PendingDepositTxn;
      get_mode2_pending_deposit_txns : shared query (_page: ?ListPage, _size: ?ListSize) -> async TrieList<TxHashId, PendingDepositTxn>;
      get_mode2_deposit_txn : shared query (_txHash: TxHash) -> async ?(DepositTxn, Timestamp);
      get_pool_balance : shared query (_token: ?EthAddress) -> async Wei;
      get_fee_balance : shared query (_token: ?EthAddress) -> async Wei;
      get_tx : shared query (_txi: TxIndex) -> async ?TxStatus;
      get_retrieval : shared query (_txi: TxIndex) -> async ?RetrieveStatus;
      get_retrieval_list : shared query (_account: Account) -> async [RetrieveStatus];
      get_retrieving : shared query (_token: {#all; #eth; #token:EthAddress}, _account: ?Account) -> async [(TxIndex, TxStatus, Timestamp)];
      get_ck_tokens : shared query () -> async [(EthAddress, TokenInfo)];
      get_event : shared query (_blockIndex: BlockHeight) -> async ?(Event, Timestamp);
      get_event_first_index : shared query () -> async BlockHeight;
      get_event_count : shared query () -> async Nat;
      get_events : shared query (_page: ?ListPage, _size: ?ListSize) -> async TrieList<BlockHeight, (Event, Timestamp)>;
      get_account_events : shared query (_accountId: AccountId) -> async [(Event, Timestamp)];

      keeper_setRpc : shared (_act: {#remove; #put:(name: Text, url: Text, status: {#Available; #Unavailable})}, _sa: ?Sa) -> async Bool;
      get_keepers : shared query () -> async TrieList<AccountId, Keeper>;
      get_rpc_providers : shared query () -> async TrieList<AccountId, RpcProvider>;

      getOwner : shared query () -> async Principal;
      getCkTokenWasmVersion : shared query () -> async (Text, Nat);
      getCkTokenWasmHistory : shared query () -> async [(Text, Nat)];
  };
}