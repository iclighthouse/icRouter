import Time "mo:base/Time";
import SagaTM "mo:ictc/SagaTM";
import Minter "mo:icl/icETHMinter";

module {
    public type Timestamp = Nat; // seconds
    public type Sa = [Nat8];
    public type Account = { owner : Principal; subaccount : ?[Nat8] };
    public type AccountId = Blob;
    public type EventBlockHeight = Nat;
    public type BlockHeight = Nat;
    public type TxIndex = Nat;
    public type Address = Text;
    public type Nonce = Nat;
    public type Toid = SagaTM.Toid;
    public type Ttid = SagaTM.Ttid;
    public type Order<T> = SagaTM.Order<T>;
    public type Task<T> = SagaTM.Task<T>;
    public type SagaData<T> = {
        autoClearTimeout: Int; 
        index: Nat; 
        firstIndex: Nat; 
        orders: [(Toid, Order<T>)]; 
        aliveOrders: [(Toid, Time.Time)]; 
        taskEvents: [(Toid, [Ttid])];
        actuator: {
            tasks: ([(Ttid, Task<T>)], [(Ttid, Task<T>)]); 
            taskLogs: [(Ttid, SagaTM.TaskEvent<T>)]; 
            errorLogs: [(Nat, SagaTM.ErrorLog)]; 
            callees: [(SagaTM.Callee, SagaTM.CalleeStatus)]; 
            index: Nat; 
            firstIndex: Nat; 
            errIndex: Nat; 
            firstErrIndex: Nat; 
        }; 
    };
    public type EthAddress = Text;
    public type Wei = Nat;
    public type HashId = Blob;
    public type TokenId = Blob;
    public type TokenCanisterId = Principal;
    public type Chain = Text;
    public type ICAccount = (TokenCanisterId, Account);
    public type ChainAccount = (Chain, TokenId, Address);
    public type BackupRequest = {
        #otherData;
        #icrc1WasmHistory; // Latest version
        #accounts;
        #tokens; 
        #deposits; 
        #balances; 
        #feeBalances; 
        #retrievals; 
        #withdrawals; 
        #pendingRetrievals; 
        #transactions; 
        #depositTxns; 
        #pendingDepositTxns; 
        #ck_keepers; 
        #ck_rpcProviders; 
        #ck_rpcLogs; 
        #ck_rpcRequests; 
        #kyt_accountAddresses; // **
        #kyt_addressAccounts; // **
        #kyt_txAccounts; // **
        #blockEvents;
        #accountEvents; // **
        #cyclesMonitor;
        #sagaData: {#All; #Base};
    };

    public type BackupResponse<T> = {
        #otherData: {
            countMinting: Nat;
            totalMinting: Wei;
            countRetrieval: Nat;
            totalRetrieval: Wei;
            quoteToken: Text;
            txIndex: TxIndex;
            ck_chainId: Nat;
            ck_ethBlockNumber: (blockheight: BlockHeight, time: Timestamp);
            ck_gasPrice: Wei;
            rpcId: Minter.RpcId;
            firstRpcId: Minter.RpcId;
            rpcRequestId: Minter.RpcRequestId;
            firstRpcRequestId: Minter.RpcRequestId;
            blockIndex : BlockHeight;
            firstBlockIndex : BlockHeight;
            ictc_admins: [Principal];
        };
        #icrc1WasmHistory: [(wasm: [Nat8], version: Text)]; // Latest version
        #accounts: [(AccountId, (EthAddress, Nonce))];
        #tokens: [(EthAddress, Minter.TokenInfo)]; 
        #deposits: [(AccountId, TxIndex)]; 
        #balances: [(AccountId, [(Minter.EthTokenId, (Account, Wei))])]; 
        #feeBalances: [(Minter.EthTokenId, Wei)]; 
        #retrievals: [(TxIndex, Minter.RetrieveStatus)]; 
        #withdrawals: [(AccountId, [TxIndex])]; 
        #pendingRetrievals: [TxIndex]; 
        #transactions: [(TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp, coveredTime: ?Timestamp))]; 
        #depositTxns: [(Minter.TxHashId, (tx: Minter.DepositTxn, updatedTime: Timestamp))]; 
        #pendingDepositTxns: [(Minter.TxHashId, Minter.PendingDepositTxn)]; 
        #ck_keepers: [(AccountId, Minter.Keeper)]; 
        #ck_rpcProviders: [(AccountId, Minter.RpcProvider)]; 
        #ck_rpcLogs: [(Minter.RpcId, Minter.RpcLog)]; 
        #ck_rpcRequests: [(Minter.RpcRequestId, Minter.RpcRequestConsensus)]; 
        #kyt_accountAddresses: [(AccountId, [ChainAccount])]; // **
        #kyt_addressAccounts: [(Address, [ICAccount])]; // **
        #kyt_txAccounts: [(HashId, [(ChainAccount, ICAccount)])]; // **
        #blockEvents: [(BlockHeight, (Minter.Event, Timestamp))];
        #accountEvents: [(AccountId, [BlockHeight])]; // **
        #cyclesMonitor: [(Principal, Nat)];
        #sagaData: SagaData<T>;
    };
};