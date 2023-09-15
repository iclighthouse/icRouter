// saoh7-yaaaa-aaaao-ahy7q-cai

module {
  public type AccessList = { storage_keys : [[Nat8]]; address : [Nat8] };
  public type Item = {
    #Num : Nat64;
    #Raw : [Nat8];
    #Empty;
    #List : List;
    #Text : Text;
  };
  public type List = { values : [Item] };
  public type Result = { #Ok : ([Nat8], [Nat8]); #Err : Text };
  public type Result_1 = { #Ok; #Err : Text };
  public type Result_2 = { #Ok : Transaction; #Err : Text };
  public type Result_3 = { #Ok : [Nat8]; #Err : Text };
  public type Result_4 = { #Ok : List; #Err : Text };
  public type Result_5 = { #Ok : ?[Nat8]; #Err : Text };
  public type Signature = {
    r : [Nat8];
    s : [Nat8];
    v : Nat64;
    from : ?[Nat8];
    hash : [Nat8];
  };
  public type Transaction = {
    #EIP1559 : Transaction1559;
    #EIP2930 : Transaction2930;
    #Legacy : TransactionLegacy;
  };
  public type Transaction1559 = {
    to : [Nat8]; // 20bytes
    value : [Nat8]; // 32bytes
    max_priority_fee_per_gas : [Nat8];
    data : [Nat8];
    sign : ?Signature;
    max_fee_per_gas : [Nat8];
    chain_id : Nat64;
    nonce : [Nat8];
    gas_limit : [Nat8];
    access_list : [AccessList];
  };
  public type Transaction2930 = {
    to : [Nat8];
    value : [Nat8];
    data : [Nat8];
    sign : ?Signature;
    chain_id : Nat64;
    nonce : [Nat8];
    gas_limit : [Nat8];
    access_list : [AccessList];
    gas_price : [Nat8];
  };
  public type TransactionLegacy = {
    to : [Nat8];
    value : [Nat8];
    data : [Nat8];
    sign : ?Signature;
    chain_id : Nat64;
    nonce : [Nat8];
    gas_limit : [Nat8];
    gas_price : [Nat8];
  };
  public type Self = actor {
    create_transaction : shared query Transaction -> async Result;
    encode_signed_transaction : shared query Transaction -> async Result;
    is_valid_public : shared query [Nat8] -> async Result_1;
    is_valid_signature : shared query [Nat8] -> async Result_1;
    keccak256 : shared query [Nat8] -> async [Nat8];
    parse_transaction : shared query [Nat8] -> async Result_2;
    pub_to_address : shared query [Nat8] -> async Result_3;
    recover_public_key : shared query (signature: [Nat8], msg: [Nat8]) -> async Result_3;
    rlp_decode : shared query [Nat8] -> async Result_4;
    rlp_encode : shared query List -> async Result_3;
    verify_proof : shared query ([Nat8], [Nat8], [[Nat8]]) -> async Result_5;
  }
}