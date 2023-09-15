// This is a generated Motoko binding.
// Please use `import service "ic:canister_id"` instead to call canisters on the IC if possible.

module {
  public type HttpHeader = { value : Text; name : Text };
  public type HttpResponse = {
    status : Nat;
    body : [Nat8];
    headers : [HttpHeader];
  };
  public type Result = { #Ok : Text; #Err : Text };
  public type TransformArgs = { context : [Nat8]; response : HttpResponse };
  public type Self = actor {
    batch_request : shared () -> async Result;
    get_block : shared ?Nat64 -> async Result;
    get_canister_addr : shared () -> async Result;
    get_eth_balance : shared Text -> async Result;
    get_eth_gas_price : shared () -> async Result;
    rpc_call : shared Text -> async Result;
    send_eth : shared (Text, Nat64) -> async Result;
    send_token : shared (Text, Text, Nat64) -> async Result;
    token_balance : shared (Text, Text) -> async Result;
    transform : shared query TransformArgs -> async HttpResponse;
  }
}