// aaaaa-aa

import Curves "./ec/Curves";
import ExperimentalCycles "mo:base/ExperimentalCycles";

module {
    public type SendRequest = {
        destination_address : Text;
        amount_in_satoshi : Satoshi;
    };

    public type ECDSAPublicKeyReply = {
        public_key : Blob;
        chain_code : Blob;
    };

    public type EcdsaKeyId = {
        curve : EcdsaCurve;
        name : Text;
    };

    public type EcdsaCurve = {
        #secp256k1;
    };

    public type SignWithECDSAReply = {
        signature : Blob;
    };

    public type ECDSAPublicKey = {
        canister_id : ?Principal;
        derivation_path : [Blob];
        key_id : EcdsaKeyId;
    };

    public type SignWithECDSA = {
        message_hash : Blob;
        derivation_path : [Blob];
        key_id : EcdsaKeyId;
    };

    public type Satoshi = Nat64;
    public type MillisatoshiPerByte = Nat64;
    public type Cycles = Nat;
    public type BitcoinAddress = Text;
    public type BlockHash = [Nat8];
    public type Page = [Nat8];

    public let CURVE = Curves.secp256k1;
    
    /// The type of Bitcoin network the dapp will be interacting with.
    public type Network = {
        #Mainnet;
        #Testnet;
        #Regtest;
    };

    /// A reference to a transaction output.
    public type OutPoint = {
        txid : Blob;
        vout : Nat32;
    };

    /// An unspent transaction output.
    public type Utxo = {
        outpoint : OutPoint;
        value : Satoshi;
        height : Nat32;
    };

    /// A request for getting the balance for a given address.
    public type GetBalanceRequest = {
        address : BitcoinAddress;
        network : Network;
        min_confirmations : ?Nat32;
    };

    /// A filter used when requesting UTXOs.
    public type UtxosFilter = {
        #MinConfirmations : Nat32;
        #Page : Page; // 1000 utxos per Page
    };

    /// A request for getting the UTXOs for a given address.
    public type GetUtxosRequest = {
        address : BitcoinAddress;
        network : Network;
        filter : ?UtxosFilter;
    };

    /// The response returned for a request to get the UTXOs of a given address.
    public type GetUtxosResponse = {
        utxos : [Utxo];
        tip_block_hash : BlockHash;
        tip_height : Nat32;
        next_page : ?Page;
    };

    /// A request for getting the current fee percentiles.
    public type GetCurrentFeePercentilesRequest = {
        network : Network;
    };

    public type SendTransactionRequest = {
        transaction : [Nat8];
        network : Network;
    };
    public type Self = actor {
        bitcoin_get_balance : GetBalanceRequest -> async Satoshi;
        bitcoin_get_utxos : GetUtxosRequest -> async GetUtxosResponse;
        bitcoin_get_current_fee_percentiles : GetCurrentFeePercentilesRequest -> async [MillisatoshiPerByte];
        bitcoin_send_transaction : SendTransactionRequest -> async ();
        ecdsa_public_key : ECDSAPublicKey -> async ECDSAPublicKeyReply;
        sign_with_ecdsa : SignWithECDSA -> async SignWithECDSAReply;
    };

    // The fees for the various Bitcoin endpoints.
    let GET_BALANCE_COST_CYCLES : Cycles = 100_000_000;
    let GET_UTXOS_COST_CYCLES : Cycles = 10_000_000_000;
    let GET_CURRENT_FEE_PERCENTILES_COST_CYCLES : Cycles = 100_000_000;
    let SEND_TRANSACTION_BASE_COST_CYCLES : Cycles = 5_000_000_000;
    let SEND_TRANSACTION_COST_CYCLES_PER_BYTE : Cycles = 20_000_000;
    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;

    let management_canister_actor : Self = actor("aaaaa-aa");

    /// Returns the balance of the given Bitcoin address.
  ///
  /// Relies on the `bitcoin_get_balance` endpoint.
  /// See https://internetcomputer.org/docs/current/references/ic-interface-spec/#ic-bitcoin_get_balance
  public func get_balance(network : Network, address : BitcoinAddress) : async Satoshi {
    ExperimentalCycles.add(GET_BALANCE_COST_CYCLES);
    await management_canister_actor.bitcoin_get_balance({
        address;
        network;
        min_confirmations = null;
    })
  };

  /// Returns the UTXOs of the given Bitcoin address.
  ///
  /// NOTE: Pagination is ignored in this example. If an address has many thousands
  /// of UTXOs, then subsequent calls to `bitcoin_get_utxos` are required.
  ///
  /// See https://internetcomputer.org/docs/current/references/ic-interface-spec/#ic-bitcoin_get_utxos
  public func get_utxos(network : Network, address : BitcoinAddress) : async GetUtxosResponse {
    ExperimentalCycles.add(GET_UTXOS_COST_CYCLES);
    await management_canister_actor.bitcoin_get_utxos({
        address;
        network;
        filter = null;
    })
  };

  /// Returns the 100 fee percentiles measured in millisatoshi/byte.
  /// Percentiles are computed from the last 10,000 transactions (if available).
  ///
  /// Relies on the `bitcoin_get_current_fee_percentiles` endpoint.
  /// See https://internetcomputer.org/docs/current/references/ic-interface-spec/#ic-bitcoin_get_current_fee_percentiles
  public func get_current_fee_percentiles(network : Network) : async [MillisatoshiPerByte] {
    ExperimentalCycles.add(GET_CURRENT_FEE_PERCENTILES_COST_CYCLES);
    await management_canister_actor.bitcoin_get_current_fee_percentiles({
        network;
    })
  };

  /// Sends a (signed) transaction to the Bitcoin network.
  ///
  /// Relies on the `bitcoin_send_transaction` endpoint.
  /// See https://internetcomputer.org/docs/current/references/ic-interface-spec/#ic-bitcoin_send_transaction
  public func send_transaction(network : Network, transaction : [Nat8]) : async () {
    let transaction_fee =
        SEND_TRANSACTION_BASE_COST_CYCLES + transaction.size() * SEND_TRANSACTION_COST_CYCLES_PER_BYTE;

    ExperimentalCycles.add(transaction_fee);
    await management_canister_actor.bitcoin_send_transaction({
        network;
        transaction;
    })
  };

  let ecdsa_canister_actor : Self = actor("aaaaa-aa");

  /// Returns the ECDSA public key of this canister at the given derivation path.
  public func ecdsa_public_key(key_name : Text, derivation_path : [Blob]) : async Blob {
    // Retrieve the public key of this canister at derivation path
    // from the ECDSA API.
    let res = await ecdsa_canister_actor.ecdsa_public_key({
        canister_id = null;
        derivation_path;
        key_id = {
            curve = #secp256k1;
            name = key_name;
        };
    });
        
    res.public_key
  };

  public func sign_with_ecdsa(key_name : Text, derivation_path : [Blob], message_hash : Blob) : async Blob {
    ExperimentalCycles.add(ECDSA_SIGN_CYCLES);
    let res = await ecdsa_canister_actor.sign_with_ecdsa({
        message_hash;
        derivation_path;
        key_id = {
            curve = #secp256k1;
            name = key_name;
        };
    });
        
    res.signature
  };

};