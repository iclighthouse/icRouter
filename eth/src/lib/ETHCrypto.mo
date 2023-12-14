import Prelude "mo:base/Prelude";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Error "mo:base/Error";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";
import Debug "mo:base/Debug";
import Tools "mo:icl/Tools";
import ABI "ABI";
import ETHUtils "mo:icl/ETHUtils";
import JSON "mo:json/JSON";
import RLP "RLP";
import SHA3 "mo:sha3/lib";

module {
    public type EthAddress = Text;
    public type Transaction = ETHUtils.Transaction;
    public type Transaction1559 = ETHUtils.Transaction1559;

    private func _vAttempt(_signature: [Nat8], _v: Nat, _msg: [Nat8], _signer: EthAddress, _chainId: Nat, _utils: Principal) : async* Nat64{
        var temp = _v;
        if (temp >= 27 and temp < 35){
            temp -= 27;
        }else if (temp >= _chainId * 2 + 35){
            temp -= _chainId * 2 + 35;
        };
        let utils: ETHUtils.Self = actor(Principal.toText(_utils));
        let v = Nat8.fromNat(temp);
        // switch(await utils.is_valid_signature(Tools.arrayAppend(_signature, [v]))){
        //     case(#Ok){
                switch(await utils.recover_public_key(Tools.arrayAppend(_signature, [v]), _msg)){
                    case(#Ok(pubKey)){ 
                        switch(await utils.pub_to_address(pubKey)){
                            case(#Ok(address)){
                                if (ABI.toHex(address) == _signer){
                                    return Nat64.fromNat(Nat8.toNat(v)); 
                                }else if (v < 3){
                                    return await* _vAttempt(_signature, Nat8.toNat(v)+1, _msg, _signer, _chainId, _utils);
                                }else{
                                    throw Error.reject("Mismatched signature or wrong v-value"); 
                                };
                            };
                            case(#Err(e)){
                                throw Error.reject(e); 
                            };
                        };
                    };
                    case(#Err(e)){ throw Error.reject(e); };
                };
        //     };
        //     case(#Err(e)){
        //         throw Error.reject(e); 
        //     };
        // };  
    };

    public func sha3(_msg: [Nat8]): [Nat8]{
        var sha = SHA3.Keccak(256);
        sha.update(_msg);
        return sha.finalize();
    };

    public func recover(rsv: {r: [Nat8]; s: [Nat8]; v: Nat64}, _chainId: Nat, _msg: [Nat8], _utils: Principal) : async* EthAddress{
        var temp: Nat = Nat64.toNat(rsv.v);
        if (temp >= 27 and temp < 35){
            temp -= 27;
        }else if (temp >= _chainId * 2 + 35){
            temp -= _chainId * 2 + 35;
        };
        let _signature = Tools.arrayAppend(Tools.arrayAppend(rsv.r, rsv.s), ABI.fromNat(temp));
        let utils: ETHUtils.Self = actor(Principal.toText(_utils));
        switch(await utils.recover_public_key(_signature, _msg)){
            case(#Ok(pubKey)){ 
                switch(await utils.pub_to_address(pubKey)){
                    case(#Ok(address)){
                        return ABI.toHex(address);
                    };
                    case(#Err(e)){
                        throw Error.reject(e); 
                    };
                };
            };
            case(#Err(e)){ throw Error.reject(e); };
        };
    };

    public func convertSignature(_sign: [Nat8], _msg: [Nat8], _signer: EthAddress, _chainId: Nat, _utils: Principal) : async* {r: [Nat8]; s: [Nat8]; v: Nat64}{
        let r = Tools.slice(_sign, 0, ?31);
        let s = Tools.slice(_sign, 32, ?63);
        var v : Nat64 = 0;
        if (_sign.size() == 65){
            v := Nat64.fromNat(ABI.toNat(ABI.toBytes32(Tools.slice(_sign, 64, null))));
        }else{
            v := await* _vAttempt(_sign, 0, _msg, _signer, _chainId, _utils);
        };
        //if (n < 27){ v += 27; };
        //if (n < 27){ v += chainId*2 + 35; }; // EIP155
        // EIP1559: 0 1 ?2 ?3
        return {r = r; s = s; v = v; };
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
                // let utils: ETHUtils.Self = actor(Principal.toText(_utils));
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