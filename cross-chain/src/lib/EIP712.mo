// https://eips.ethereum.org/EIPS/eip-712

import SHA3 "SHA3";
import Prelude "mo:base/Prelude";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import ABI "ABI";

module {
    public type HexStr = Text; //e.g. 0x1234567890abcdef
    public type Value = {
        #bool: Bool;
        #bytes32: HexStr;
        #uint256: Nat;
        #address: HexStr;
        #array: [Value];
        #struct: [Value];
        #string: Text;
        #bytes: [Nat8];
    };

    public func hashMessage(_domainType: Text, _domainValues: [Value], _messageType: Text, _messageValues: [Value]) : (raw: [Nat8], hash: [Nat8]){
        var data = Buffer.Buffer<Nat8>(1);
        data.add(0x19);
        data.add(0x01);
        data.append(Buffer.fromArray<Nat8>(hashStruct(_domainType, _domainValues)));
        data.append(Buffer.fromArray<Nat8>(hashStruct(_messageType, _messageValues)));
        var sha = SHA3.Keccak(256);
        sha.update(Buffer.toArray(data));
        let hash = sha.finalize();
        return (Buffer.toArray(data), hash);
    };

    public func hashStruct(_type: Text, _values: [Value]) : [Nat8]{
        var sha = SHA3.Keccak(256);
        var data = Buffer.fromArray<Nat8>(hashType(_type));
        data.append(Buffer.fromArray<Nat8>(encodeData(_values)));
        sha.update(Buffer.toArray(data));
        let hash = sha.finalize();
        return hash;
    };

    public func hashType(_type: Text): [Nat8]{
        var sha = SHA3.Keccak(256);
        sha.update(Blob.toArray(Text.encodeUtf8(_type)));
        return sha.finalize();
    };

    public func encodeData(_values: [Value]): [Nat8]{
        var data = Buffer.Buffer<Nat8>(1);
        for(value in _values.vals()){
            switch(value){
                case(#bool(v)){
                    if (v) {
                        data.append(Buffer.fromArray<Nat8>(ABI.toBytes32([1:Nat8])));
                    } else {
                        data.append(Buffer.fromArray<Nat8>(ABI.toBytes32([0:Nat8])));
                    };
                };
                case(#bytes32(v)){
                    switch(ABI.fromHex(v)){
                        case(?(r)){ data.append(Buffer.fromArray<Nat8>(ABI.toBytes32(r))); };
                        case(_){ Prelude.unreachable(); };
                    };
                };
                case(#uint256(v)){
                    data.append(Buffer.fromArray<Nat8>(ABI.natABIEncode(v)));
                };
                case(#address(v)){
                    data.append(Buffer.fromArray<Nat8>(ABI.addressABIEncode(v)));
                };
                case(#array(v)){
                    data.append(Buffer.fromArray<Nat8>(encodeData(v)));
                };
                case(#struct(v)){
                    var sha = SHA3.Keccak(256);
                    sha.update(encodeData(v));
                    let hash = sha.finalize();
                    data.append(Buffer.fromArray<Nat8>(hash));
                };
                case(#string(v)){
                    var sha = SHA3.Keccak(256);
                    sha.update(Blob.toArray(Text.encodeUtf8(v)));
                    let hash = sha.finalize();
                    data.append(Buffer.fromArray<Nat8>(hash));
                };
                case(#bytes(v)){
                    var sha = SHA3.Keccak(256);
                    sha.update(v);
                    let hash = sha.finalize();
                    data.append(Buffer.fromArray<Nat8>(hash));
                };
            };
        };
        return Buffer.toArray(data);
    };
};