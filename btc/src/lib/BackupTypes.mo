import Time "mo:base/Time";
import SagaTM "mo:ictc/SagaTM";
import Minter "mo:icl/icBTCMinter";
import ICBTC "mo:icl/Bitcoin";

module {
    public type Timestamp = Nat; // seconds
    public type Sa = [Nat8];
    public type Account = { owner : Principal; subaccount : ?[Nat8] };
    public type AccountId = Blob;
    public type EventBlockHeight = Nat;
    public type BlockHeight = Nat;
    public type TxIndex = Nat;
    public type Address = Text;
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
    public type PubKey = [Nat8];
    public type DerivationPath = [Blob];
    public type ICUtxo = ICBTC.Utxo;
    public type Utxo = {
        height : Nat32;
        value : Nat64; // Satoshi
        outpoint : { txid : [Nat8]; vout : Nat32 }; // txid: Blob
    };
    public type VaultUtxo = (Address, PubKey, DerivationPath, ICUtxo);
    public type HashId = Blob;
    public type TokenId = Blob;
    public type TokenCanisterId = Principal;
    public type Chain = Text;
    public type ICAccount = (TokenCanisterId, Account);
    public type ChainAccount = (Chain, TokenId, Address);
    public type BackupRequest = {
        #otherData;
        #minterUtxos;
        #accountUtxos; // Record the latest utxo for each account
        #retrieveBTC; 
        #sendingBTC; 
        #icrc1WasmHistory; // Latest version
        #kyt_accountAddresses; // **
        #kyt_addressAccounts; // **
        #kyt_txAccounts; // **
        #icEvents;
        #icAccountEvents; // **
        #cyclesMonitor;
    };

    public type BackupResponse = {
        #otherData: {
            minterRemainingBalance: Nat64;
            totalBtcFee: Nat64;
            totalBtcReceiving: Nat64;
            totalBtcSent: Nat64;
            feeBalance: Nat64;
            txInProcess: [TxIndex];
            txIndex: TxIndex;
            firstTxIndex: TxIndex;
            eventBlockIndex: Nat;
            firstBlockIndex: Nat;
            ictc_admins: [Principal];
        };
        #minterUtxos: ([VaultUtxo], [VaultUtxo]);
        #accountUtxos: [(Address, (PubKey, DerivationPath, [ICBTC.Utxo]))]; // Record the latest utxo for each account
        #retrieveBTC: [(EventBlockHeight, Minter.RetrieveStatus)]; 
        #sendingBTC: [(TxIndex, Minter.SendingBtcStatus)]; 
        #icrc1WasmHistory: [(wasm: [Nat8], version: Text)]; // Latest version
        #kyt_accountAddresses: [(AccountId, [ChainAccount])]; // **
        #kyt_addressAccounts: [(Address, [ICAccount])]; // **
        #kyt_txAccounts: [(HashId, [(ChainAccount, ICAccount)])]; // **
        #icEvents: [(BlockHeight, (Minter.Event, Timestamp))];
        #icAccountEvents: [(AccountId, [BlockHeight])]; // **
        #cyclesMonitor: [(Principal, Nat)];
    };
};