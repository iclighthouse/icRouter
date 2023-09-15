// aaaaa-aa

import ExperimentalCycles "mo:base/ExperimentalCycles";

module {

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

    public type Cycles = Nat;

    
    public type Self = actor {
        ecdsa_public_key : ECDSAPublicKey -> async ECDSAPublicKeyReply;
        sign_with_ecdsa : SignWithECDSA -> async SignWithECDSAReply;
    };

    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;

    let ecdsa_canister_actor : Self = actor("aaaaa-aa");

    /// Returns the ECDSA public key of this canister at the given derivation path.
    public func ecdsa_public_key(key_name : Text, derivation_path : [Blob]) : async* Blob {
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

    public func sign_with_ecdsa(key_name : Text, derivation_path : [Blob], message_hash : Blob) : async* Blob {
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