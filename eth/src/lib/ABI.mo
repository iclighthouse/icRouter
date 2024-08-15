import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Option "mo:base/Option";
import List "mo:base/List";
import Hex "mo:icl/Hex";

module {
    type Account = [Nat8];
    type Address = Text;
    type BigNat = (Nat64, Nat64, Nat64, Nat64);
    // private func _toBigNat(_nat: Nat) : BigNat{
    //     let A1: Nat64 = Nat64.fromNat(_nat / (2**192));
    //     let _nat2: Nat = (_nat - Nat64.toNat(A1) * (2**192));
    //     let A2: Nat64 = Nat64.fromNat(_nat2 / (2**128));
    //     let _nat3: Nat = (_nat2 - Nat64.toNat(A2) * (2**128));
    //     let A3: Nat64 = Nat64.fromNat(_nat3 / (2**64));
    //     let A4: Nat64 = Nat64.fromNat(_nat3 - Nat64.toNat(A3) * (2**64));
    //     return (A1, A2, A3, A4);
    // };
    // private func _toNat(_bignat: BigNat) : Nat{
    //     return Nat64.toNat(_bignat.0) * (2**192) + Nat64.toNat(_bignat.1) * (2**128) + Nat64.toNat(_bignat.2) * (2**64) + Nat64.toNat(_bignat.3);
    // };

    // **********Tools************

    public func arrayAppend<T>(a: [T], b: [T]) : [T]{
        let buffer = Buffer.Buffer<T>(1);
        for (t in a.vals()){
            buffer.add(t);
        };
        for (t in b.vals()){
            buffer.add(t);
        };
        return Buffer.toArray(buffer);
    };
    public func slice<T>(a: [T], from: Nat, to: ?Nat): [T]{
        let len = a.size();
        if (len == 0) { return []; };
        var to_: Nat = Option.get(to, Nat.sub(len, 1));
        if (len <= to_){ to_ := len - 1; };
        var na: [T] = [];
        var i: Nat = from;
        while ( i <= to_ ){
            na := arrayAppend(na, Array.make(a[i]));
            i += 1;
        };
        return na;
    };

    public func shrink20(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() > 20){
            ret := slice(ret, 1, null);
        };
        return ret;
    };
    public func shrinkBytes(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() > 1 and ret[0] == 0){
            ret := slice(ret, 1, null);
        };
        return ret;
    };
    public func shrink(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() > 0 and ret[0] == 0){
            ret := slice(ret, 1, null);
        };
        return ret;
    };
    public func toBytes32(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() < 32){
            ret := arrayAppend([0:Nat8], ret);
        };
        return ret;
    };

    public func toHex(_data: [Nat8]) : Text{
        return "0x"#Hex.encode(_data);
    };
    public func fromHex(_hexWith0x: Text) : ?[Nat8]{
        if (_hexWith0x.size() >= 2){
            var hex = Option.get(Text.stripStart(_hexWith0x, #text("0x")), _hexWith0x);
            if (hex.size() % 2 > 0){ hex := "0"#hex; };
            if (hex == "") { return ?[] };
            switch(Hex.decode(hex)){
                case(#ok(r)){ return ?r; };
                case(_){ return null; };
            };
        };
        return null;
    };
    public func fromNat(_nat: Nat) : [Nat8]{
        // let bignat = _toBigNat(_nat);
        // let b0 = Binary.BigEndian.fromNat64(bignat.0);
        // let b1 = Binary.BigEndian.fromNat64(bignat.1);
        // let b2 = Binary.BigEndian.fromNat64(bignat.2);
        // let b3 = Binary.BigEndian.fromNat64(bignat.3);
        // return arrayAppend(arrayAppend(b0, b1), arrayAppend(b2, b3));
        var a : Nat8 = 0;
        var b : Nat = _nat;
        var bytes = List.nil<Nat8>();
        var test = true;
        while(test) {
        a := Nat8.fromNat(b % 256);
        b := b / 256;
        bytes := List.push<Nat8>(a, bytes);
        test := b > 0;
        };
        List.toArray<Nat8>(bytes);
    };
    public func toNat(_data: [Nat8]) : Nat{
        // assert(_data.size() == 32);
        // let b0 = slice(_data, 0, ?7);
        // let b1 = slice(_data, 8, ?15);
        // let b2 = slice(_data, 16, ?23);
        // let b3 = slice(_data, 24, ?31);
        // let bignat : BigNat = (
        //     Binary.BigEndian.toNat64(b0), 
        //     Binary.BigEndian.toNat64(b1), 
        //     Binary.BigEndian.toNat64(b2), 
        //     Binary.BigEndian.toNat64(b3)
        // );
        // return _toNat(bignat);
        var n : Nat = 0;
        for(bit in _data.vals()){
            n := n * 256 + Nat8.toNat(bit);
        };
        return n;
    };
    public func natToHex(_n: Nat) : Text{
        return toHex(fromNat(_n));
    };

    // **********ABI Encode/Decode************

    public func natABIEncode(_nat: Nat) : [Nat8]{
        return toBytes32(fromNat(_nat));
    };
    public func natABIDecode(_data: [Nat8]) : Nat{
        return toNat(_data);
    };

    public func accountABIEncode(_account: Account) : [Nat8]{
        assert(_account.size() == 20);
        return toBytes32(_account);
    };
    public func accountABIDecode(_data: [Nat8]) : Account{
        assert(_data.size() == 32);
        return shrink20(_data);
    };
    public func addressABIEncode(_address: Text) : [Nat8]{
        assert(_address.size() == 42);
        switch(fromHex(_address)){
            case(?(account)){
                return toBytes32(account);
            };
            case(_){
                assert(false);
                return [];
            };
        };
    };

    // **********ERC20 CallData Encode/Decode************
        // {
        //     "dd62ed3e": "allowance(address,address)", //call
        //     "095ea7b3": "approve(address,uint256)",
        //     "70a08231": "balanceOf(address)", //call
        //     "42966c68": "burn(uint256)",
        //     "313ce567": "decimals()", //call
        //     "40c10f19": "mint(address,uint256)",
        //     "06fdde03": "name()", //call
        //     "8da5cb5b": "owner()", //call
        //     "8456cb59": "pause()",
        //     "5c975abb": "paused()", //call
        //     "95d89b41": "symbol()", //call
        //     "18160ddd": "totalSupply()", //call
        //     "a9059cbb": "transfer(address,uint256)",
        //     "23b872dd": "transferFrom(address,address,uint256)",
        //     "3f4ba83a": "unpause()"
        // }
    /// name()
    public func encodeErc20Name(): [Nat8]{
        switch(fromHex("0x06fdde03")){
            case(?(bytes)){ bytes };
            case(_){ [] };
        };
    };
    /// symbol()
    public func encodeErc20Symbol(): [Nat8]{
        switch(fromHex("0x95d89b41")){
            case(?(bytes)){ bytes };
            case(_){ [] };
        };
    };
    public func decodeErc20Symbol(_strHex: Text): Text{
        if (_strHex.size() <= 2){
            return "";
        };
        switch(fromHex(_strHex)){
            case(?(bytes)){
                let length: Nat = toNat(slice(bytes, 32, ?63));
                return Option.get(Text.decodeUtf8(Blob.fromArray(slice(bytes, 64, ?(63 + length)))), "");
            };
            case(_){ return ""; };
        };
    };
    /// decimals()
    public func encodeErc20Decimals(): [Nat8]{
        switch(fromHex("0x313ce567")){
            case(?(bytes)){ bytes };
            case(_){ [] };
        };
    };
    /// totalSupply()
    public func encodeErc20TotalSupply(): [Nat8]{
        switch(fromHex("0x18160ddd")){
            case(?(bytes)){ bytes };
            case(_){ [] };
        };
    };
    /// balanceOf(address)
    public func encodeErc20BalanceOf(_owner: Text): [Nat8]{
        var data : [Nat8] = [];
        switch(fromHex("0x70a08231")){
            case(?(bytes)){ data := bytes };
            case(_){};
        };
        return arrayAppend(data, addressABIEncode(_owner));
    };
    /// allowance(address,address)
    public func encodeErc20Allowance(_owner: Text, _spender: Text): [Nat8]{
        var data : [Nat8] = [];
        switch(fromHex("0xdd62ed3e")){
            case(?(bytes)){ data := bytes };
            case(_){};
        };
        return arrayAppend(arrayAppend(data, addressABIEncode(_owner)), addressABIEncode(_spender));
    };
    /// approve(address,uint256)
    public func encodeErc20Approve(_spender: Text, _value: Nat): [Nat8]{
        var data : [Nat8] = [];
        switch(fromHex("0x095ea7b3")){
            case(?(bytes)){ data := bytes };
            case(_){};
        };
        return arrayAppend(arrayAppend(data, addressABIEncode(_spender)), natABIEncode(_value));
    };
    /// transfer(address,uint256)
    public func encodeErc20Transfer(_to: Text, _value: Nat): [Nat8]{
        var data : [Nat8] = [];
        switch(fromHex("0xa9059cbb")){
            case(?(bytes)){ data := bytes };
            case(_){};
        };
        return arrayAppend(arrayAppend(data, addressABIEncode(_to)), natABIEncode(_value));
    };
    public func decodeErc20Transfer(_data: [Nat8]): ?{to: Text; value: Nat}{
        if (_data.size() < 68){
            return null;
        };
        if (_data[0] == 0xa9 and _data[1] == 0x05 and _data[2] == 0x9c and _data[3] == 0xbb){
            let to = toHex(accountABIDecode(slice(_data, 4, ?35)));
            let value = natABIDecode(slice(_data, 36, ?67));
            return ?{to = to; value = value};
        }else{
            return null;
        };
    };
    /// transferFrom(address,address,uint256)
    public func encodeErc20TransferFrom(_from: Text, _to: Text, _value: Nat): [Nat8]{
        var data : [Nat8] = [];
        switch(fromHex("0x23b872dd")){
            case(?(bytes)){ data := bytes };
            case(_){};
        };
        return arrayAppend(arrayAppend(arrayAppend(data, addressABIEncode(_from)), addressABIEncode(_to)), natABIEncode(_value));
    };
    public func decodeErc20TransferFrom(_data: [Nat8]): ?{from: Text; to: Text; value: Nat}{
        if (_data.size() < 100){
            return null;
        };
        if (_data[0] == 0x23 and _data[1] == 0xb8 and _data[2] == 0x72 and _data[3] == 0xdd){
            let from = toHex(accountABIDecode(slice(_data, 4, ?35)));
            let to = toHex(accountABIDecode(slice(_data, 36, ?67)));
            let value = natABIDecode(slice(_data, 68, ?99));
            return ?{from = from; to = to; value = value};
        }else{
            return null;
        };
    };
};