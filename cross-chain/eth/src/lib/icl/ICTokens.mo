/**
 * Module     : ICTokens.mo
 * Author     : ICLight.house Team
 * Github     : https://github.com/iclighthouse/DRC_standards/
 */
module {
  public type AccountId = Blob;
  public type Address = Text;
  public type From = Address;
  public type To = Address;
  public type Amount = Nat;
  public type Sa = [Nat8];
  public type Nonce = Nat;
  public type Data = Blob;
  public type Time = Int;
  public type Txid = Blob;
  public type Config = { //ict
        feeTo: ?Address;
    };
  public type Self = actor {
    standard : shared query () -> async Text;
    ictokens_maxSupply : shared query () -> async ?Nat;
    ictokens_top100 : shared query () -> async [(Address, Amount)];
    ictokens_heldFirstTime : shared query Address -> async ?Int;
    ictokens_config : shared Config -> async Bool;
    ictokens_getConfig : shared query () -> async Config;
    ictokens_addMinter : shared (_minter: Principal) -> async Bool;
    ictokens_snapshot : shared Amount -> async Bool;
    ictokens_clearSnapshot : shared () -> async Bool;
    ictokens_getSnapshot : shared query (Nat, Nat) -> async (Int, [(AccountId, Nat)], Bool);
    ictokens_snapshotBalanceOf : shared query (Nat, Address) -> async (Int, ?Nat);
  }
}