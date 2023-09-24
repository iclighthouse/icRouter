import Result "mo:base/Result";
import Buffer "mo:base/Buffer";

module {
    public type AccountIdentifier = Text;
    public type SubAccount = [Nat8];
    public type User = {
        #address : AccountIdentifier; //No notification
        #principal : Principal; //defaults to sub account 0
    };
    public type Balance = Nat;
    public type TokenIdentifier  = Text;
    public type TokenIndex = Nat32;
    public type TokenObj = {
        index : TokenIndex;
        canister : [Nat8];
    };
    public type Extension = Text;
    public type Memo = Blob;
    public type CommonError = {
        #InvalidToken: TokenIdentifier;
        #Other : Text;
    };
    public type BalanceRequest = { 
        user : User; 
        token: TokenIdentifier;
    };
    public type TransferRequest = {
        from : User;
        to : User;
        token : TokenIdentifier;
        amount : Balance;
        memo : Memo;
        notify : Bool;
        subaccount : ?SubAccount;
    };
    public type NotifyCallback = shared (TokenIdentifier, User, Balance, Memo) -> async ?Balance;
    public type NotifyService = actor { tokenTransferNotification : NotifyCallback};
    public type AllowanceRequest = {
        owner : User;
        spender : Principal;
        token : TokenIdentifier;
    };

    public type ApproveRequest = {
        subaccount : ?SubAccount;
        spender : Principal;
        allowance : Balance;
        token : TokenIdentifier;
    };
    public type Metadata = {
        #fungible : {
            name : Text;
            symbol : Text;
            decimals : Nat8;
            metadata : ?Blob;
        };
        #nonfungible : {
            metadata : ?Blob;
        };
    };
    public type TransferResponse = Result.Result<Balance, {
        #Unauthorized: AccountIdentifier;
        #InsufficientBalance;
        #Rejected; //Rejected by canister
        #InvalidToken: TokenIdentifier;
        #CannotNotify: AccountIdentifier;
        #Other : Text;
    }>;
    public type Self = actor {
        allowance: shared query (AllowanceRequest) -> async (Result.Result<Balance, CommonError>);
        approve: shared (ApproveRequest) -> async (Bool);
        balance: shared query (BalanceRequest) -> async (Result.Result<Balance, CommonError>);
        bearer: shared query (TokenIdentifier) -> async (Result.Result<AccountIdentifier, CommonError>);
        metadata: shared query (TokenIdentifier) -> async (Result.Result<Metadata, CommonError>);
        getTokens: shared query () -> async ([(TokenIndex, Metadata)]);
        supply: shared query (TokenIdentifier) -> async (Result.Result<Balance, CommonError>);
        transfer: shared (request: TransferRequest) -> async (TransferResponse);
    };
};