import Prelude "mo:base/Prelude";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Error "mo:base/Error";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";
import Tools "mo:icl/Tools";
import ABI "ABI";
import Minter "mo:icl/icETHMinter";
import ETHUtils "mo:icl/ETHUtils";
import JSON "mo:json/JSON";
import RLP "RLP";
import SHA3 "mo:sha3/lib";
import ICECDSA "ICECDSA";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import PublicKey "mo:libsecp256k1/PublicKey";
import Signature "mo:libsecp256k1/Signature";
import Message "mo:libsecp256k1/Message";
import RecoveryId "mo:libsecp256k1/RecoveryId";
import Ecdsa "mo:libsecp256k1/Ecdsa";
import ECMult "mo:libsecp256k1/core/ecmult";

module {
    public type EthAddress = Text;
    public type TxType = {#EIP1559; #EIP2930; #Legacy};
    public type Transaction = ETHUtils.Transaction;
    // https://github.com/iclighthouse/evm-txs.mo/blob/main/test/TestContext.mo
    // public let ecGenCtx = Ecmult.ECMultGenContext(?Ecmult.loadPrec(Prec.prec));
    // public let ecCtx = Ecmult.ECMultContext(?Ecmult.loadPreG(PreG.pre_g));
    public func getEcContext(): ECMult.ECMultContext{
        return ECMult.ECMultContext(null); 
    };

    private func _vTest(_signature: [Nat8], _v: Nat, _msg: [Nat8], _msgHash: [Nat8], _signer: EthAddress, _chainId: Nat, _ecCtx: ECMult.ECMultContext) : Result.Result<Nat64, Text>{
        var temp = _v;
        if (temp >= 27 and temp < 35){
            temp -= 27;
        }else if (temp >= _chainId * 2 + 35){
            temp -= _chainId * 2 + 35;
        };
        let v = Nat8.fromNat(temp);
        switch(Signature.parse_standard(_signature)) {
            case (#ok(signatureParsed)) {
                switch(RecoveryId.parse(v)) {
                    case (#ok(recoveryIdParsed)) {
                        let messageParsed = Message.parse(_msgHash);
                        switch(Ecdsa.recover_with_context(messageParsed, signatureParsed, recoveryIdParsed, _ecCtx)) {
                            case (#ok(publicKey)) {
                                switch(pubToAddress(publicKey.serialize_compressed())){
                                    case(#ok(address)){
                                        if (address == _signer){
                                            return #ok(Nat64.fromNat(Nat8.toNat(v))); 
                                        }else if (v < 3){
                                            return _vTest(_signature, Nat8.toNat(v)+1, _msg, _msgHash, _signer, _chainId, _ecCtx);
                                        }else{
                                            return #err("Mismatched signature or wrong v-value"); 
                                        };
                                    };
                                    case(#err(msg)){
                                        return #err(debug_show msg);
                                    };
                                };
                            };
                            case (#err(msg)) {
                                return #err(debug_show msg);
                            };
                        };  
                    };
                    case (#err(msg)) {
                        return #err(debug_show msg);
                    };
                };
            };
            case (#err(msg)) {
                return #err(debug_show msg);
            };
        };
    };

    public func sha3(_msg: [Nat8]): [Nat8]{
        var sha = SHA3.Keccak(256);
        sha.update(_msg);
        return sha.finalize();
    };

    // fn pubkey_bytes_to_address(pubkey_bytes: &[u8]) -> String {
    //     use k256::elliptic_curve::sec1::ToEncodedPoint;
    //     let key = PublicKey::from_sec1_bytes(pubkey_bytes).expect("failed to parse the public key as SEC1");
    //     let point = key.to_encoded_point(false);
    //     // we re-encode the key to the decompressed representation.
    //     let point_bytes = point.as_bytes();
    //     assert_eq!(point_bytes[0], 0x04);
    //     let hash = keccak256(&point_bytes[1..]);
    //     ethers_core::utils::to_checksum(&Address::from_slice(&hash[12..32]), None)
    // }
    public func pubToAddress(_pubKey: [Nat8]) : Result.Result<Text, Text>{ //_pubKey: 33 bytes
        let publicKey = _pubKey;
        if(publicKey.size() != 33) {
            return #err("Invalid length of public key");
        };
        switch(PublicKey.parse_compressed(publicKey)) {
            case (#err(e)) {
                return #err("Invalid public key");
            };
            case (#ok(pub)) {
                let pubKey: [Nat8] = Tools.slice(pub.serialize(), 1, null);
                let hash: [Nat8] = sha3(pubKey);
                let account: [Nat8] = Tools.slice(hash, Nat.sub(hash.size(), 20), null);
                return #ok(ABI.toHex(account));
            };
        };
    };

    public func buildTransaction(_tx: Minter.TxStatus, _txType: TxType, _chainId: Nat, _isERC20: Bool, _to: ?EthAddress, _value: ?Nat) : Transaction{
        let tx = _tx;
        var to: EthAddress = Option.get(_to, tx.to);
        var amount: Nat = Option.get(_value, tx.amount);
        var data: [Nat8] = [];
        if (_isERC20){
            to := tx.tokenId;
            amount := 0;
            data := ABI.encodeErc20Transfer(to, amount);
        };
        switch(_txType){
            case(#EIP1559){
                return #EIP1559({
                    to = Option.get(ABI.fromHex(to), []);
                    value = ABI.natABIEncode(amount);
                    max_priority_fee_per_gas = ABI.natABIEncode(Nat.max(tx.fee.gasPrice / 10, 100000000)); 
                    data = data;
                    sign = null;
                    max_fee_per_gas = ABI.natABIEncode(tx.fee.gasPrice);
                    chain_id = Nat64.fromNat(_chainId);
                    nonce = ABI.natABIEncode(Option.get(tx.nonce, 0));
                    gas_limit = ABI.natABIEncode(tx.fee.gasLimit);
                    access_list = [];
                });
            };
            case(#EIP2930){
                Prelude.unreachable();
            };
            case(#Legacy){
                Prelude.unreachable();
            };
        };
    };

    public func buildSignedTransaction(_transaction: ETHUtils.Transaction, _sign: ?ETHUtils.Signature) : Transaction{
        switch(_transaction){
            case(#EIP1559(txObj)){
                return #EIP1559({
                    to = txObj.to;
                    value = txObj.value;
                    max_priority_fee_per_gas = txObj.max_priority_fee_per_gas; 
                    data = txObj.data;
                    sign = _sign;
                    max_fee_per_gas = txObj.max_fee_per_gas;
                    chain_id = txObj.chain_id;
                    nonce = txObj.nonce;
                    gas_limit = txObj.gas_limit;
                    access_list = txObj.access_list;
                });
            };
            case(#EIP2930(txObj)){
                Prelude.unreachable();
            };
            case(#Legacy(txObj)){
                Prelude.unreachable();
            };
        };
    };

    public func signMsg(_dpath: [Blob], _msgHash : [Nat8], _cycles: Nat, _keyName: Text) : async* [Nat8] {
        let ic : ICECDSA.Self = actor("aaaaa-aa");
        Cycles.add<system>(_cycles);
        let res = await ic.sign_with_ecdsa({
            message_hash = Blob.fromArray(_msgHash);
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = _keyName; };
        });
        return Blob.toArray(res.signature);
    };

    public func recover(_sign: [Nat8], _msg: [Nat8], _msgHash: [Nat8], _signer: EthAddress, _chainId: Nat, _ecCtx: ECMult.ECMultContext) : Result.Result<Text, Text>{
        if(_msgHash.size() != 32) {
            return #err("Invalid message");
        };
        var recoveryId : Nat8 = 0;
        var signature = _sign;
        if (_sign.size() == 65){
            recoveryId := Nat8.fromNat(ABI.toNat(ABI.toBytes32(Tools.slice(_sign, 64, null))));
            signature := Tools.slice(_sign, 0, ?63);
        }else if (_sign.size() == 64){
            switch(_vTest(_sign, 0, _msg, _msgHash, _signer, _chainId, _ecCtx)){
                case(#ok(v)){
                    recoveryId := Nat8.fromNat(Nat64.toNat(v));
                };
                case(_){
                    return #err("Invalid recoveryId (v).");
                };
            };
        }else{
            return #err("Invalid signature");
        };
        // return #ok("debug: "# Nat8.toText(recoveryId));
        switch(Signature.parse_standard(signature)) {
            case (#ok(signatureParsed)) {
                switch(RecoveryId.parse(recoveryId)) {
                    case (#ok(recoveryIdParsed)) {
                        let messageParsed = Message.parse(_msgHash);
                        switch(Ecdsa.recover_with_context(messageParsed, signatureParsed, recoveryIdParsed, _ecCtx)) {
                            case (#ok(publicKey)) {
                                let address = pubToAddress(publicKey.serialize_compressed());
                                return address;
                            };
                            case (#err(msg)) {
                                return #err(debug_show msg);
                            };
                        };
                    };
                    case (#err(msg)) {
                        return #err(debug_show msg);
                    };
                };
            };
            case (#err(msg)) {
                return #err(debug_show msg);
            };
        };
    };

    public func convertSignature(_sign: [Nat8], _msg: [Nat8], _msgHash: [Nat8], _signer: EthAddress, _chainId: Nat, _ecCtx: ECMult.ECMultContext) : Result.Result<{r: [Nat8]; s: [Nat8]; v: Nat64}, Text>{
        if (_sign.size() < 64){
            return #err("Invalid signature.");
        };
        let r = Tools.slice(_sign, 0, ?31);
        let s = Tools.slice(_sign, 32, ?63);
        var v : Nat64 = 0;
        if (_sign.size() == 65){
            v := Nat64.fromNat(ABI.toNat(ABI.toBytes32(Tools.slice(_sign, 64, null))));
        }else{
            switch(_vTest(_sign, 0, _msg, _msgHash, _signer, _chainId, _ecCtx)){
                case(#ok(v_)){
                    v := v_;
                };
                case(_){
                    return #err("Invalid recoveryId (v).");
                };
            };
        };
        //if (n < 27){ v += 27; };
        //if (n < 27){ v += chainId*2 + 35; }; // EIP155
        // EIP1559: 0 1 ?2 ?3
        return #ok({r = r; s = s; v = v; });
    };
    public func rlpEncode(_tx: Transaction) : [Nat8]{ // rlpEncode(_tx: Transaction, _utils: Principal) : async* [Nat8]{
        switch(_tx){
            case(#EIP1559(_tx1559)){
                if (_tx1559.access_list.size() > 0){
                    Prelude.unreachable();
                };
                // ETHUtils
                // var values: [ETHUtils.Item] = [
                //     #Num(_tx1559.chain_id),
                //     #Num(ABI.toNat(_tx1559.nonce)),
                //     #Raw(ABI.shrink(_tx1559.max_priority_fee_per_gas)),
                //     #Raw(ABI.shrink(_tx1559.max_fee_per_gas)),
                //     #Raw(ABI.shrink(_tx1559.gas_limit)),
                //     #Raw(_tx1559.to),
                //     #Raw(ABI.shrink(_tx1559.value)),
                //     #Raw(_tx1559.data),
                //     #List({ values = [] })
                // ];
                // switch(_tx1559.sign){
                //     case(?signature){
                //         values := Tools.arrayAppend(values, [
                //             #Num(signature.v),
                //             #Raw(signature.r),
                //             #Raw(signature.s),
                //         ]);
                //     };
                //     case(_){};
                // };
                // let utils: ETHUtils.Self = actor(_utils);
                // let res1 = await utils.rlp_encode({values = values});
                // RLP
                var input: RLP.InputList = Buffer.fromArray<RLP.Input>([]);
                input.add(#number(Nat64.toNat(_tx1559.chain_id)));
                // input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(_tx1559.nonce))));
                input.add(#number(ABI.toNat(_tx1559.nonce)));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(_tx1559.max_priority_fee_per_gas))));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(_tx1559.max_fee_per_gas))));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(_tx1559.gas_limit))));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(_tx1559.to)));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(_tx1559.value))));
                input.add(#Uint8Array(Buffer.fromArray<Nat8>(_tx1559.data)));
                input.add(#List(Buffer.fromArray<RLP.Input>([])));
                switch(_tx1559.sign){
                    case(?signature){
                        // input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(ABI.fromNat(Nat64.toNat(signature.v))))));
                        input.add(#number(Nat64.toNat(signature.v)));
                        input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(signature.r))));
                        input.add(#Uint8Array(Buffer.fromArray<Nat8>(ABI.shrink(signature.s))));
                    };
                    case(_){};
                };
                let res2: [Nat8] = Buffer.toArray(RLP.encode(#List(input)));
                // return
                // switch(res1){
                //     case(#Ok(data)){
                //         if (data != res2){
                //             throw Error.reject(debug_show(data) # debug_show(res2));
                //         };
                //         return Tools.arrayAppend([2:Nat8], data);
                //     };
                //     case(#Err(e)){
                //         throw Error.reject(e);
                //     };
                // };
                return Tools.arrayAppend([2:Nat8], res2);
            };
            case(_){
                Prelude.unreachable();
            };
        };
    };
    public func trimQuote(str: Text): Text{
        if (Text.startsWith(str, #char '\"') and Text.endsWith(str, #char '\"')){
            return Option.get(Text.stripEnd(Option.get(Text.stripStart(str, #char '\"'), str), #char '\"'), str);
        }else{
            return str;
        };
    };
    public func strLeft(str: Text, left: Nat): Text{
        var i: Nat = 0;
        return Text.translate(str, func (c: Char): Text{
            i += 1;
            if (i <= left){ Text.fromChar(c) } else { "" };
        });
    };
    public func strRight(str: Text, right: Nat): Text{
        let len = Text.size(str);
        var i: Nat = 0;
        var offset: Nat = 0;
        if (len > right){
            offset := Nat.sub(len, right);
        };
        return Text.translate(str, func (c: Char): Text{
            i += 1;
            if (i > offset){ Text.fromChar(c) } else { "" };
        });
    };
    public func getStringFromJson(json: Text, key: Text) : ?Text{ // key: "aaa/bbb"
        if (key == "" or key == "/"){
            return ?json;
        };
        let keys = Iter.toArray(Text.split(key, #char('/')));
        switch(JSON.parse(json)){
            case(?(#Object(obj))){
                if (keys.size() > 0){
                    for ((k, v) in obj.vals()){
                        if ( k == keys[0]){
                            var keys2: [Text] = [];
                            for (x in keys.keys()){
                                if (x > 0){
                                    keys2 := Tools.arrayAppend(keys2, [keys[x]]);
                                };
                            };
                            let res = getStringFromJson(JSON.show(v), Text.join("/", keys2.vals()));
                            return res;
                        };
                    };
                };
            };
            case(?(#String(str))){ //"result"
                return ?str;
            };
            case(?(#Null)){
                return ?"";
            };
            case(_){};
        };
        return null;
    };
    public func getBytesFromJson(json: Text, key: Text) : ?[Nat8]{ // key: "aaa/bbb"
        let keys = Iter.toArray(Text.split(key, #char('/')));
        switch(JSON.parse(json)){
            case(?(#Object(obj))){
                if (keys.size() > 0){
                    for ((k, v) in obj.vals()){
                        if ( k == keys[0]){
                            var keys2: [Text] = [];
                            for (x in keys.keys()){
                                if (x > 0){
                                    keys2 := Tools.arrayAppend(keys2, [keys[x]]);
                                };
                            };
                            let res = getBytesFromJson(JSON.show(v), Text.join("/", keys2.vals()));
                            return res;
                        };
                    };
                };
            };
            case(?(#String(str))){ //"result"
                return ABI.fromHex(str);
            };
            case(?(#Null)){
                return ?[];
            };
            case(_){};
        };
        return null;
    };
    public func getValueFromJson(json: Text, key: Text) : ?Nat{
        switch(getBytesFromJson(json, key)){
            case(?(bytes)){
                return ?ABI.toNat(ABI.toBytes32(bytes));
            };
            case(_){};
        };
        return null;
    };
};