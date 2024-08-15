// https://github.com/icdevs/rlp.mo
import Buffer "mo:base/Buffer";
import Blob "mo:base/Blob";
import D "mo:base/Debug";
import Hex "mo:icl/Hex";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";

module {

  public type Uint8Array = Buffer.Buffer<Nat8>;

  public type Input = {
    #string : Text;
    #number: Nat;
    #Uint8Array : Uint8Array;
    #List: InputList;
    #Null;
    #Undefined;
  };

  public type InputList = Buffer.Buffer<Input>;

  public type NestedUint8Array = {
    #Uint8Array: Uint8Array;
    #Nested: Buffer.Buffer<NestedUint8Array>;
  };

  public type Decoded = {
    data : NestedUint8Array;
    remainder : Buffer.Buffer<Nat8>;
  };

  public type DecodedResult = {
    #Nested: NestedUint8Array;
    #Decoded: Decoded;
    #Uint8Array: Uint8Array;
  };


/**
 * RLP Encoding based on https://eth.wiki/en/fundamentals/rlp
 * This function takes in data, converts it to Buffer<Nat8> if not,
 * and adds a length for recursion.
 * @param input Will be converted to Buffer<Nat8>
 * @returns Buffer<Nat8> of encoded data
 **/
  public func encode(input: Input) : Uint8Array { // fixed
    switch(input) {
      // case(#Uint8Array(item)) {
      //   let result = encodeLength(item.size(), 128); 
      //   result.append(item);
      //   return result;
      // };
      case(#List(item)) {
        let output = Buffer.Buffer<Nat8>(1);
        for(thisItem in item.vals()) {
          output.append(encode(thisItem));
        };
        let result = encodeLength(output.size(), 192);
        result.append(output);
        return result;
      };
      case(_){ // #Uint8Array #string #number #Null
        let inputBuf = toBytes(input);
        // if (inputBuf.size() == 0) { // fixed
        //   return encodeLength(0, 128);
        // }else 
        if (inputBuf.size() == 1 and inputBuf.get(0) < 128) {
          return inputBuf;
        }else{
          let result = encodeLength(inputBuf.size(), 128);
          result.append(inputBuf);
          return result;
        };
      };
    };
  };

  // Slices a Buffer<Nat8>, throws if the slice goes out-of-bounds of the Uint8Array.
  // E.g. `safeSlice(hexToBytes("aa"), 1, 2)` will throw.
  // @param input
  // @param start
  // @param end

  public func safeSlice(input: Uint8Array, start: Nat, end: Nat) : Uint8Array {
    if (end > input.size()) { 
      D.trap("invalid RLP (safeSlice): end slice of Uint8Array out-of-bounds");
    };
    let output = Buffer.Buffer<Nat8>(end - start);
    var tracker = 0;
    loop {
      if(tracker >= start) {
        output.add(input.get(tracker));
        tracker += 1;
        if(tracker > end) {
          return output;
        };
      };
    };
  };

  /*
  * Parse integers. Check if there is no leading zeros
  * @param v The value to parse
  * @param base The base to parse the integer into
  */
  public func decodeLength(v: Uint8Array): Nat8 {
    if (v.get(0) == 0 and v.get(1) == 0) {
      D.trap("invalid RLP: extra zeros");
    };
    return  switch(Hex.decode(Hex.encode(Buffer.toArray(v)))){case(#ok(val)){val[0]};case(#err(err)){return D.trap("not a valid hex")}};
  };

  public func encodeLength(len: Nat, offset: Nat): Uint8Array {
    if (len < 56) {
      return toBuffer<Nat8>([Nat8.fromNat(len) + Nat8.fromNat(offset)]);
    };
    let hexLength = numberToHex(len);
    let lLength = hexLength.size() / 2;
    let firstByte = numberToHex(offset + 55 + lLength);
    let result = switch(Hex.decode(firstByte # hexLength)){case(#ok(val)){val};case(#err(err)){return D.trap("not a valid hex")}};
    let output = toBuffer<Nat8>(result);

    return output;
  };

  /**
  * RLP Decoding based on https://eth.wiki/en/fundamentals/rlp
  * @param input Will be converted to Uint8Array
  * @param stream Is the input a stream (false by default)
  * @returns decoded Array of Uint8Arrays containing the original message
  **/
  public func decode(input: Input): DecodedResult {
    switch(input) {
      case(#string(item)) {
        if(item.size() == 0) { 
          return #Uint8Array(Buffer.Buffer(1));
        };
      };
      case(#Uint8Array(item)) {
        if(item.size() == 0) {
          return #Uint8Array(Buffer.Buffer(1));
        };
      };
      case(#List(item)) {
        if(item.size() == 0) { 
          return #Uint8Array(Buffer.Buffer(1));
        };
      };
      case(#Null) {
        return #Uint8Array(Buffer.Buffer(1));
      };
      case(#Undefined) {
        return #Uint8Array(Buffer.Buffer(1));
      };
      case(_){};
    };

    let inputBytes = toBytes(input);
    let decoded = _decode(inputBytes);


    if (decoded.remainder.size() != 0) {
      D.trap("invalid RLP: remainder must be zero");
    };

    return switch(decoded.data) {
      case(#Nested(item)) {
        #Nested(#Nested(item));
      };
      case(#Uint8Array(item)) {
        #Uint8Array(item);
      };
    };
  };

  let threshold : Nat8 = 127; //7f matchr Hex.decode("7f"), val[0], D.trap("unreachable")
  let threshold2 : Nat8 = 183; //b7 matchr Hex.decode("b7"), val[0], D.trap("unreachable")
  let threshold3 : Nat8 = 247;//f7 switch(Hex.decode("f7")){case(#ok(val)){val[0]};case(#err(err)){D.trap("unreachable")}};
 
  let threshold4 : Nat8 = 182; //b6  matchr Hex.decode("b6"), val[0], D.trap("unreachable")
  let threshold5 : Nat8 = 191; //bf matchr Hex.decode("bf"), val[0], D.trap("unreachable")
  let nullbyte : Nat8 = 128; //80 matchr Hex.decode("80"), val[0], D.trap("unreachable")


  /** Decode an input with RLP */
  private func _decode(input: Uint8Array): Decoded {
    
    // var decoded = [];
    var firstByte = input.get(0);

    // a single byte whose value is in the [0x00, 0x7f] range, that byte is its own RLP encoding.
    if (firstByte <= threshold) {
      return {
        data = #Uint8Array(safeSlice(input, 0, 1));
        remainder = if (input.size() > 2)
            safeSlice(input, 1, input.size() - 1)
          else
            Buffer.Buffer<Nat8>(1);
      };
    }
    else if (firstByte <= threshold2) {
      // string is 0-55 bytes long. A single byte with value 0x80 plus the length of the string followed by the string
      // The range of the first byte is [0x80, 0xb7]
      let length :  Nat8 = firstByte - threshold;

      // set 0x80 null to 0
      let data = if (firstByte == nullbyte) {
        Buffer.Buffer<Nat8>(1);
      }
      else {
        safeSlice(input, 1, Nat8.toNat(length));
      };

      if (length == 2 and data.get(0) < nullbyte) { 
        D.trap("invalid RLP encoding: invalid prefix, single byte < 0x80 are not prefixed");
      };

      return {
        data = #Uint8Array(data);
        remainder = safeSlice(input, Nat8.toNat(length), input.size() - 1);
      };
    }
    else if (firstByte <= threshold5) {
      // string is greater than 55 bytes long. A single byte with the value (0xb7 plus the length of the length),
      // followed by the length, followed by the string
      let llength = firstByte - threshold4;
      if (Nat.sub(input.size(),1) < Nat8.toNat(llength)) {
        D.trap("invalid RLP: not enough bytes for string length");
      };

      let length = decodeLength(safeSlice(input, 1, Nat8.toNat(llength)));
      if (length <= 55) {
        D.trap("invalid RLP: expected string length to be greater than 55");
      };

      let data = safeSlice(input, Nat8.toNat(llength), Nat8.toNat(length + llength));

      return {
        data = #Uint8Array(data);
        remainder = if (input.size() > Nat8.toNat(length + llength)) {
          safeSlice(input, Nat8.toNat(length + llength), input.size() - 1);
        }
        else {
          Buffer.Buffer<Nat8>(1);
        };
      };
    }
    else if (firstByte <= threshold3) {
      // a list between  0-55 bytes long
      let length = firstByte - threshold4;
      var innerRemainder = safeSlice(input, 1, Nat8.toNat(length));
      let decoded = Buffer.Buffer<NestedUint8Array>(1);
      while (innerRemainder.size() > 0) {
        let d = _decode(innerRemainder);
        
        decoded.add(d.data);
        innerRemainder := d.remainder;
      };

      return {
        data = #Nested(decoded);
        remainder = if (input.size() > Nat8.toNat(length)) {
          safeSlice(input, Nat8.toNat(length), input.size() - 1);
        }
        else {
          Buffer.Buffer<Nat8>(1);
        };
      };
    }
    else {
      // a list  over 55 bytes long
      let llength = firstByte - threshold4;
      let length = decodeLength(safeSlice(input, 1, Nat8.toNat(llength)));
      if (length < 56) {
        D.trap("invalid RLP: encoded list too short");
      };
      let totalLength = llength + length;
      if (Nat8.toNat(totalLength) > input.size()) {
        D.trap("invalid RLP: total length is larger than the data");
      };

      var innerRemainder = safeSlice(input,Nat8.toNat( llength), Nat8.toNat(totalLength));

      let decoded = Buffer.Buffer<NestedUint8Array>(1);
      while (innerRemainder.size() > 0) {
        let d = _decode(innerRemainder);
        decoded.add(d.data);
        innerRemainder := d.remainder;
      };

      return {
        data = #Nested(decoded);
        remainder = if (input.size() > Nat8.toNat(totalLength)) {
          safeSlice(input, Nat8.toNat(totalLength), input.size() - 1);
        }
        else {
          Buffer.Buffer<Nat8>(1);
        };
      };
    };
  };

  /** Transform an integer into its hexadecimal value */
  public func numberToHex(integer: Nat): Text {
    return(Hex.encode(natToBytes(integer)));
  };

  public func natToBytes(n : Nat) : [Nat8] { 
    var a : Nat8 = 0;
    var b : Nat = n;
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


  /** Pad a string to be even */
  public func padToEven(a: Text): Text { 
    return if (a.size() % 2 == 1) {
      "0" # a;  
    }
    else { 
      a;
    };
  };

  /** Check if a string is prefixed by 0x */
  public func isHexPrefixed(str: Text): Bool {
    let charArray = Iter.toArray(str.chars());
    return if ((str.size() >= 2) and (charArray[0] == '0') and  (charArray[1] == 'x')) {
      true;
    }
    else {
      false;
    };
  };

  /** Removes 0x from a given String */
  public func stripHexPrefix(str: Text): Text { 
    return if (isHexPrefixed(str))
        switch(Text.stripStart(str, #text("0x"))){case(null){str};case(?val){val}}

      else 
        str;
  };

  public func trimPrefixZero(_data: [Nat8]) : [Nat8]{ // [00,01,00,02] -> [01,00,02];  [00] -> []
      let buffer = Buffer.Buffer<Nat8>(1);
      var flag: Bool = false;
      for (byte in _data.vals()){ 
        if (byte > 0){
          flag := true;
        };
        if (flag){
          buffer.add(byte);
        };
      };
      return Buffer.toArray(buffer);
  };

  /** Transform anything into a Uint8Array */
  public func toBytes(v: Input): Uint8Array {
    switch(v) {
      case(#Uint8Array(item)) {
        return item;
      };
      case(#string(item)) {
        if (isHexPrefixed(item)) {
          return toBuffer<Nat8>(switch(Hex.decode(padToEven(stripHexPrefix(item)))){case(#ok(val)){val};case(#err(err)){D.trap("nat a valid hex")}});
        };
        return toBuffer<Nat8>(Blob.toArray(Text.encodeUtf8(item)));
      };
      case(#number(v)) { //? fixed
        // return switch(Hex.decode(Hex.encodeByte(Nat8.fromNat(v)))){case(#ok(val)){toBuffer<Nat8>(val)};case(#err(err)){D.trap("not a valid hex")}};
        return toBuffer<Nat8>(trimPrefixZero(natToBytes(v)));
      };
      // case(#bigint(v)) { //? fixed
      //   // return switch(Hex.decode(Hex.encodeByte(Nat8.fromNat(v)))){case(#ok(val)){toBuffer<Nat8>(val)};case(#err(err)){D.trap("not a valid hex")}};
      //   return toBuffer<Nat8>(trimPrefixZero(natToBytes(v)));
      // };
      case(#Null) {
        return Buffer.Buffer<Nat8>(1);
      };
      case(#Undefined) {
        return Buffer.Buffer<Nat8>(1);
      };
      case(_){};
    };
    D.trap("toBytes: received unsupported type ");
  };

  private func toBuffer<T>(x :[T]) : Buffer.Buffer<T> {
    let thisBuffer = Buffer.Buffer<T>(x.size());
    for(thisItem in x.vals()) {
      thisBuffer.add(thisItem);
    };
    return thisBuffer;
  };
};