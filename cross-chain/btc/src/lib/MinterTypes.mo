import ICBTC "bitcoin/ICBTC";
import Script "bitcoin/lib/Script";

module {
  public type Timestamp = Nat; // seconds
  public type Sa = [Nat8];
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public type AccountId = Blob;
  public type EventBlockHeight = Nat;
  public type BlockHeight = Nat;
  public type TxIndex = Nat;
  public type ListPage = Nat;
  public type ListSize = Nat;
  public type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };
  public type Address = Text;
  public type TypeAddress = {
    #p2pkh : Text;
  };
  public type BitcoinAddress = {
    #p2sh : [Nat8];
    #p2wpkh_v0 : [Nat8];
    #p2pkh : [Nat8];
  };
  public type BtcNetwork = { #Mainnet; #Regtest; #Testnet };
  public type EventOldVerson = {
    #received_utxos : { to_account : Account; utxos : [Utxo] };
    #sent_transaction : {
      change_output : ?{ value : Nat64; vout : Nat32 };
      txid : [Nat8];
      utxos : [Utxo];
      requests : [Nat64]; // blockIndex
      submitted_at : Nat64; // txi
    };
    #init : InitArgsOldVersion;
    #upgrade : UpgradeArgs;
    #accepted_retrieve_btc_request : {
      received_at : Nat64;
      block_index : Nat64;
      address : BitcoinAddress;
      amount : Nat64;
    };
    #removed_retrieve_btc_request : { block_index : Nat64 };
    #confirmed_transaction : { txid : [Nat8] };
  };
  public type Mode = {
    #ReadOnly;
    #RestrictedTo : [Principal];
    #GeneralAvailability;
  };
  public type InitArgsOldVersion = {
    ecdsa_key_name : Text;
    retrieve_btc_min_amount : Nat64;
    ledger_id : Principal;
    max_time_in_queue_nanos : Nat64;
    btc_network : BtcNetwork;
    min_confirmations: ?Nat32;
    mode : Mode;
  };
  public type InitArgs = {
    retrieve_btc_min_amount : Nat64;
    ledger_id : Principal;
    min_confirmations: ?Nat32;
    fixed_fee: Nat;
    dex_pair: ?Principal;
    mode : Mode;
  };
  public type UpgradeArgs = {
      retrieve_btc_min_amount : ?Nat64;
      max_time_in_queue_nanos : ?Nat64;
      min_confirmations : ?Nat32;
      mode : ?Mode;
  };
  public type TokenInfo = {
    symbol: Text;
    decimals: Nat8;
    totalSupply: ?Nat;
    minAmount: Nat;
    ckSymbol: Text;
    ckLedgerId: Principal;
    fixedFee: Nat; // Includes KYT fee, Platform Fee.
    dexPair: ?Principal; // BTC/USDT
    dexPrice: ?(Float, Timestamp); // 1 (Satoshis) XXX = ? (Wei) USDT
  };
  public type RetrieveBtcArgs = { address : Text; amount : Nat64 };
  public type RetrieveBtcError = {
    #MalformedAddress : Text;
    #GenericError : { error_message : Text; error_code : Nat64 };
    #TemporarilyUnavailable : Text;
    #AlreadyProcessing;
    #AmountTooLow : Nat64;
    #InsufficientFunds : { balance : Nat64 };
  };
  public type RetrieveBtcOk = { block_index : Nat64 };
  public type RetrieveBtcStatus = {
    #Signing;
    #Confirmed : { txid : [Nat8] };
    #Sending : { txid : [Nat8] };
    #AmountTooLow;
    #Unknown;
    #Submitted : { txid : [Nat8] };
    #Pending;
  };
  public type UpdateBalanceError = {
    #GenericError : { error_message : Text; error_code : Nat64 };
    #TemporarilyUnavailable : Text;
    #AlreadyProcessing;
    #NoNewUtxos; //*
  };
  public type UpdateBalanceResult = { block_index : Nat64; amount : Nat64 };
  public type ICUtxo = ICBTC.Utxo; // Minter.Utxo?
  public type Utxo = {
    height : Nat32;
    value : Nat64; // Satoshi
    outpoint : { txid : [Nat8]; vout : Nat32 }; // txid: Blob
  };
  public type PubKey = [Nat8];
  public type DerivationPath = [Blob];
  public type VaultUtxo = (Address, PubKey, DerivationPath, ICUtxo);
  public type RetrieveStatus = {
    account: Account;
    retrieveAccount: Account;
    burnedBlockIndex: Nat;
    btcAddress: Address;
    amount: Nat64; // Satoshi
    txIndex: Nat;
  };
  public type SendingBtcStatus = {
    destinations: [(Nat64, Address, Nat64)]; // (blockIndex, address, amount)
    totalAmount: Nat64;
    utxos: [VaultUtxo];
    scriptSigs: [Script.Script];
    fee: Nat64;
    toids: [Nat];
    signedTx: ?[Nat8];
    status: RetrieveBtcStatus;
  };
  public type BalanceStats = {nativeBalance: Nat; totalSupply: Nat; minterBalance: Nat; feeBalance: Nat};
  public type Event = { //Timestamp = seconds
    #initOrUpgrade : {initArgs: InitArgs};
    #start: { message: ?Text };
    #suspend: { message: ?Text };
    #changeOwner: {newOwner: Principal};
    #config: {setting: {
      #setTokenWasm: {version: Text; size: Nat};
      #upgradeTokenWasm: {symbol: Text; icTokenCanisterId: Principal; version: Text};
    }};
    #sent_transaction: {
      account: Account;
      retrieveAccount: Account;
      address: Text;
      change_output : ?{ value : Nat64; vout : Nat32 };
      txid : Text;
      utxos : [Utxo];
      requests : [Nat64]; // blockIndex
    };
    #received_utxos: { to_account : Account; deposit_address : Text; utxos : [Utxo]; total_fee: Nat; amount: Nat; };
    #accepted_retrieve_btc_request: {
      txi : TxIndex;
      account: Account;
      icrc1_burned_txid: Nat;
      address: Text;
      amount: Nat64;
      total_fee: Nat;
    };
    #mint: {toid: ?Nat; account: Account; address: Text; icTokenCanisterId: Principal; amount: Nat};
    #burn: {toid: ?Nat; account: Account; address: Text; icTokenCanisterId: Principal; tokenBlockIndex: Nat; amount: Nat};
    #send: {toid: ?Nat; to: Account; icTokenCanisterId: Principal; amount: Nat};
  };
  public type Self = actor {
    get_btc_address : shared (_account : Account) -> async Text;
    update_balance : shared (_account : Account) -> async {
        #Ok : UpdateBalanceResult;
        #Err : UpdateBalanceError;
      };
    get_withdrawal_account : shared query (_account : Account) -> async Account;
    retrieve_btc : shared (RetrieveBtcArgs, ?Sa) -> async {
        #Ok : RetrieveBtcOk;
        #Err : RetrieveBtcError;
      };
    retrieve_btc_status : shared query { block_index : Nat64; } -> async RetrieveBtcStatus;
    get_events_old_version : shared query { start : Nat64; length : Nat64 } -> async [EventOldVerson];
    batch_send : shared (_txIndex: ?Nat) -> async Bool;
    retrieveLog : shared query (_blockIndex: ?Nat64) -> async ?RetrieveStatus;
    sendingLog : shared query (_txIndex: ?Nat) -> async ?SendingBtcStatus;
    utxos : shared query (_address: Address) -> async ?(PubKey, DerivationPath, [Utxo]);
    vaultUtxos : shared query () -> async (Nat64, [(Address, PubKey, DerivationPath, Utxo)]);
    get_event : shared query (_blockIndex: EventBlockHeight) -> async ?(Event, Timestamp);
    get_event_first_index : shared query () -> async EventBlockHeight;
    get_events : shared query (_page: ?ListPage, _size: ?ListSize) -> async TrieList<EventBlockHeight, (Event, Timestamp)>;
    get_account_events : shared query (_accountId: AccountId) -> async [(Event, Timestamp)];
    get_event_count : shared query () -> async Nat;
    get_ck_tokens : shared query () -> async [TokenInfo];
    get_minter_info : shared query () -> async {
        enDebug: Bool; // app_debug 
        btcNetwork: BtcNetwork; //NETWORK
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
    };
    stats : shared query () -> async {
        blockIndex: Nat64;
        txIndex: Nat;
        vaultRemainingBalance: Nat64; // minterRemainingBalance
        totalBtcFee: Nat64;
        feeBalance: Nat64;
        totalBtcReceiving: Nat64;
        totalBtcSent: Nat64;
        countAsyncMessage: Nat;
        countRejections : Nat;
    };
  }
}