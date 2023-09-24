// This is a generated Motoko binding.
// Please use `import service "ic:canister_id"` instead to call canisters on the IC if possible.

module {
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public type BitcoinAddress = {
    #p2sh : [Nat8];
    #p2wpkh_v0 : [Nat8];
    #p2pkh : [Nat8];
  };
  public type BtcNetwork = { #Mainnet; #Regtest; #Testnet };
  public type Event = {
    #received_utxos : { to_account : Account; utxos : [Utxo] };
    #sent_transaction : {
      change_output : ?{ value : Nat64; vout : Nat32 };
      txid : [Nat8];
      utxos : [Utxo];
      requests : [Nat64];
      submitted_at : Nat64;
    };
    #distributed_kyt_fee : {
      block_index : Nat64;
      amount : Nat64;
      kyt_provider : Principal;
    };
    #init : InitArgs;
    #upgrade : UpgradeArgs;
    #retrieve_btc_kyt_failed : {
      block_index : Nat64;
      uuid : Text;
      address : Text;
      amount : Nat64;
      kyt_provider : Principal;
    };
    #accepted_retrieve_btc_request : {
      received_at : Nat64;
      block_index : Nat64;
      address : BitcoinAddress;
      amount : Nat64;
      kyt_provider : ?Principal;
    };
    #checked_utxo : {
      clean : Bool;
      utxo : Utxo;
      uuid : Text;
      kyt_provider : ?Principal;
    };
    #removed_retrieve_btc_request : { block_index : Nat64 };
    #confirmed_transaction : { txid : [Nat8] };
    #ignored_utxo : { utxo : Utxo };
  };
  public type InitArgs = {
    kyt_principal : ?Principal;
    ecdsa_key_name : Text;
    mode : Mode;
    retrieve_btc_min_amount : Nat64;
    ledger_id : Principal;
    max_time_in_queue_nanos : Nat64;
    btc_network : BtcNetwork;
    min_confirmations : ?Nat32;
    kyt_fee : ?Nat64;
  };
  public type MinterArg = { #Upgrade : ?UpgradeArgs; #Init : InitArgs };
  public type MinterInfo = {
    retrieve_btc_min_amount : Nat64;
    min_confirmations : Nat32;
    kyt_fee : Nat64;
  };
  public type Mode = {
    #RestrictedTo : [Principal];
    #DepositsRestrictedTo : [Principal];
    #ReadOnly;
    #GeneralAvailability;
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
    #NoNewUtxos : {
      required_confirmations : Nat32;
      current_confirmations : ?Nat32;
    };
  };
  public type UpgradeArgs = {
    kyt_principal : ?Principal;
    mode : ?Mode;
    retrieve_btc_min_amount : ?Nat64;
    max_time_in_queue_nanos : ?Nat64;
    min_confirmations : ?Nat32;
    kyt_fee : ?Nat64;
  };
  public type Utxo = {
    height : Nat32;
    value : Nat64;
    outpoint : { txid : [Nat8]; vout : Nat32 };
  };
  public type UtxoStatus = {
    #ValueTooSmall : Utxo;
    #Tainted : Utxo;
    #Minted : { minted_amount : Nat64; block_index : Nat64; utxo : Utxo };
    #Checked : Utxo;
  };
  public type Self = MinterArg -> async actor {
    estimate_withdrawal_fee : shared query { amount : ?Nat64 } -> async {
        minter_fee : Nat64;
        bitcoin_fee : Nat64;
      };
    get_btc_address : shared {
        owner : ?Principal;
        subaccount : ?[Nat8];
      } -> async Text;
    get_deposit_fee : shared query () -> async Nat64;
    get_events : shared query { start : Nat64; length : Nat64 } -> async [
        Event
      ];
    get_minter_info : shared query () -> async MinterInfo;
    get_withdrawal_account : shared () -> async Account;
    retrieve_btc : shared RetrieveBtcArgs -> async {
        #Ok : RetrieveBtcOk;
        #Err : RetrieveBtcError;
      };
    retrieve_btc_status : shared query {
        block_index : Nat64;
      } -> async RetrieveBtcStatus;
    update_balance : shared {
        owner : ?Principal;
        subaccount : ?[Nat8];
      } -> async { #Ok : [UtxoStatus]; #Err : UpdateBalanceError };
  }
}