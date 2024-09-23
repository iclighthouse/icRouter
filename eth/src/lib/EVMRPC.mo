module {
  public type Auth = { #RegisterProvider; #FreeRpc; #PriorityRpc; #Manage };
  public type Block = {
    miner : Text;
    totalDifficulty : Nat;
    receiptsRoot : Text;
    stateRoot : Text;
    hash : Text;
    difficulty : Nat;
    size : Nat;
    uncles : [Text];
    baseFeePerGas : Nat;
    extraData : Text;
    transactionsRoot : ?Text;
    sha3Uncles : Text;
    nonce : Nat;
    number : Nat;
    timestamp : Nat;
    transactions : [Text];
    gasLimit : Nat;
    logsBloom : Text;
    parentHash : Text;
    gasUsed : Nat;
    mixHash : Text;
  };
  public type BlockTag = {
    #Earliest;
    #Safe;
    #Finalized;
    #Latest;
    #Number : Nat;
    #Pending;
  };
  public type EthMainnetService = {
    #Alchemy;
    #BlockPi;
    #Cloudflare;
    #PublicNode;
    #Ankr;
  };
  public type EthSepoliaService = { #Alchemy; #BlockPi; #PublicNode; #Ankr };
  public type FeeHistory = {
    reward : [[Nat]];
    gasUsedRatio : [Float];
    oldestBlock : Nat;
    baseFeePerGas : [Nat];
  };
  public type FeeHistoryArgs = {
    blockCount : Nat;
    newestBlock : BlockTag;
    rewardPercentiles : ?Blob;
  };
  public type FeeHistoryResult = { #Ok : ?FeeHistory; #Err : RpcError };
  public type GetBlockByNumberResult = { #Ok : Block; #Err : RpcError };
  public type GetLogsArgs = {
    fromBlock : ?BlockTag;
    toBlock : ?BlockTag;
    addresses : [Text];
    topics : ?[Topic];
  };
  public type GetLogsResult = { #Ok : [LogEntry]; #Err : RpcError };
  public type GetTransactionCountArgs = { address : Text; block : BlockTag };
  public type GetTransactionCountResult = { #Ok : Nat; #Err : RpcError };
  public type GetTransactionReceiptResult = {
    #Ok : ?TransactionReceipt;
    #Err : RpcError;
  };
  public type HttpHeader = { value : Text; name : Text };
  public type HttpOutcallError = {
    #IcError : { code : RejectionCode; message : Text };
    #InvalidHttpJsonRpcResponse : {
      status : Nat16;
      body : Text;
      parsingError : ?Text;
    };
  };
  public type InitArgs = { nodesInSubnet : Nat32 };
  public type JsonRpcError = { code : Int64; message : Text };
  public type L2MainnetService = { #Alchemy; #BlockPi; #PublicNode; #Ankr };
  public type LogEntry = {
    transactionHash : ?Text;
    blockNumber : ?Nat;
    data : Text;
    blockHash : ?Text;
    transactionIndex : ?Nat;
    topics : [Text];
    address : Text;
    logIndex : ?Nat;
    removed : Bool;
  };
  public type ManageProviderArgs = {
    service : ?RpcService;
    primary : ?Bool;
    providerId : Nat64;
  };
  public type Metrics = {
    cyclesWithdrawn : Nat;
    responses : [((Text, Text, Text), Nat64)];
    errNoPermission : Nat64;
    inconsistentResponses : [((Text, Text), Nat64)];
    cyclesCharged : [((Text, Text), Nat)];
    requests : [((Text, Text), Nat64)];
    errHttpOutcall : [((Text, Text), Nat64)];
    errHostNotAllowed : [(Text, Nat64)];
  };
  public type MultiFeeHistoryResult = {
    #Consistent : FeeHistoryResult;
    #Inconsistent : [(RpcService, FeeHistoryResult)];
  };
  public type MultiGetBlockByNumberResult = {
    #Consistent : GetBlockByNumberResult;
    #Inconsistent : [(RpcService, GetBlockByNumberResult)];
  };
  public type MultiGetLogsResult = {
    #Consistent : GetLogsResult;
    #Inconsistent : [(RpcService, GetLogsResult)];
  };
  public type MultiGetTransactionCountResult = {
    #Consistent : GetTransactionCountResult;
    #Inconsistent : [(RpcService, GetTransactionCountResult)];
  };
  public type MultiGetTransactionReceiptResult = {
    #Consistent : GetTransactionReceiptResult;
    #Inconsistent : [(RpcService, GetTransactionReceiptResult)];
  };
  public type MultiSendRawTransactionResult = {
    #Consistent : SendRawTransactionResult;
    #Inconsistent : [(RpcService, SendRawTransactionResult)];
  };
  public type ProviderError = {
    #TooFewCycles : { expected : Nat; received : Nat };
    #MissingRequiredProvider;
    #ProviderNotFound;
    #NoPermission;
  };
  public type ProviderId = Nat64;
  public type ProviderView = {
    cyclesPerCall : Nat64;
    owner : Principal;
    hostname : Text;
    primary : Bool;
    chainId : Nat64;
    cyclesPerMessageByte : Nat64;
    providerId : Nat64;
  };
  public type RegisterProviderArgs = {
    cyclesPerCall : Nat64;
    credentialPath : Text;
    hostname : Text;
    credentialHeaders : ?[HttpHeader];
    chainId : Nat64;
    cyclesPerMessageByte : Nat64;
  };
  public type RejectionCode = {
    #NoError;
    #CanisterError;
    #SysTransient;
    #DestinationInvalid;
    #Unknown;
    #SysFatal;
    #CanisterReject;
  };
  public type RequestCostResult = { #Ok : Nat; #Err : RpcError };
  public type RequestResult = { #Ok : Text; #Err : RpcError };
  public type RpcApi = { url : Text; headers : ?[HttpHeader] };
  public type RpcConfig = { responseSizeEstimate : ?Nat64 };
  public type RpcError = {
    #JsonRpcError : JsonRpcError;
    #ProviderError : ProviderError;
    #ValidationError : ValidationError;
    #HttpOutcallError : HttpOutcallError;
  };
  public type RpcService = {
    #EthSepolia : EthSepoliaService;
    #BaseMainnet : L2MainnetService;
    #Custom : RpcApi;
    #OptimismMainnet : L2MainnetService;
    #ArbitrumOne : L2MainnetService;
    #EthMainnet : EthMainnetService;
    #Chain : Nat64;
    #Provider : Nat64;
  };
  public type RpcServices = {
    #EthSepolia : ?[EthSepoliaService];
    #BaseMainnet : ?[L2MainnetService];
    #Custom : { chainId : Nat64; services : [RpcApi] };
    #OptimismMainnet : ?[L2MainnetService];
    #ArbitrumOne : ?[L2MainnetService];
    #EthMainnet : ?[EthMainnetService];
  };
  public type SendRawTransactionResult = {
    #Ok : SendRawTransactionStatus;
    #Err : RpcError;
  };
  public type SendRawTransactionStatus = {
    #Ok : ?Text;
    #NonceTooLow;
    #NonceTooHigh;
    #InsufficientFunds;
  };
  public type Topic = [Text];
  public type TransactionReceipt = {
    to : Text;
    status : Nat;
    transactionHash : Text;
    blockNumber : Nat;
    from : Text;
    logs : [LogEntry];
    blockHash : Text;
    type_ : Text;
    transactionIndex : Nat;
    effectiveGasPrice : Nat;
    logsBloom : Text;
    contractAddress : ?Text;
    gasUsed : Nat;
  };
  public type UpdateProviderArgs = {
    cyclesPerCall : ?Nat64;
    credentialPath : ?Text;
    hostname : ?Text;
    credentialHeaders : ?[HttpHeader];
    primary : ?Bool;
    cyclesPerMessageByte : ?Nat64;
    providerId : Nat64;
  };
  public type ValidationError = {
    #CredentialPathNotAllowed;
    #HostNotAllowed : Text;
    #CredentialHeaderNotAllowed;
    #UrlParseError : Text;
    #Custom : Text;
    #InvalidHex : Text;
  };
  public type Self = actor {
    authorize : shared (Principal, Auth) -> async Bool;
    deauthorize : shared (Principal, Auth) -> async Bool;
    eth_feeHistory : shared (
        RpcServices,
        ?RpcConfig,
        FeeHistoryArgs,
      ) -> async MultiFeeHistoryResult;
    eth_getBlockByNumber : shared (
        RpcServices,
        ?RpcConfig,
        BlockTag,
      ) -> async MultiGetBlockByNumberResult;
    eth_getLogs : shared (
        RpcServices,
        ?RpcConfig,
        GetLogsArgs,
      ) -> async MultiGetLogsResult;
    eth_getTransactionCount : shared (
        RpcServices,
        ?RpcConfig,
        GetTransactionCountArgs,
      ) -> async MultiGetTransactionCountResult;
    eth_getTransactionReceipt : shared (
        RpcServices,
        ?RpcConfig,
        Text,
      ) -> async MultiGetTransactionReceiptResult;
    eth_sendRawTransaction : shared (
        RpcServices,
        ?RpcConfig,
        Text,
      ) -> async MultiSendRawTransactionResult;
    getAccumulatedCycleCount : shared query ProviderId -> async Nat;
    getAuthorized : shared query Auth -> async [Principal];
    getMetrics : shared query () -> async Metrics;
    getNodesInSubnet : shared query () -> async Nat32;
    getOpenRpcAccess : shared query () -> async Bool;
    getProviders : shared query () -> async [ProviderView];
    getServiceProviderMap : shared query () -> async [(RpcService, Nat64)];
    manageProvider : shared ManageProviderArgs -> async ();
    registerProvider : shared RegisterProviderArgs -> async Nat64;
    request : shared (RpcService, Text, Nat64) -> async RequestResult;
    requestCost : shared query (
        RpcService,
        Text,
        Nat64,
      ) -> async RequestCostResult;
    setOpenRpcAccess : shared Bool -> async ();
    unregisterProvider : shared ProviderId -> async Bool;
    updateProvider : shared UpdateProviderArgs -> async ();
    withdrawAccumulatedCycles : shared (ProviderId, Principal) -> async ();
  }
}