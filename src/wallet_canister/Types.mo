import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";

module {
  public let TOKENS = "wallet:tokens";
  public type ICRCTokenArg = {
    subaccount : ?Blob;
    token : Principal;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type DepositErr = {
    #GenericError : Error.Type;
    #TokenNotFound;
    #InsufficientBalance : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #BadFee : { expected_fee : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #InsufficientFunds : { balance : Nat };
    #Duplicate : { duplicate_of : Nat };
  };
  public type DepositRes = Result.Type<Nat, DepositErr>;

  public type WithdrawErr = {
    #GenericError : Error.Type;
    #InsufficientBalance : { balance : Nat };
    #BadFee : { expected_fee : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #InsufficientFunds : { balance : Nat };
    #Duplicate : { duplicate_of : Nat };
  };
  public type WithdrawRes = Result.Type<Nat, WithdrawErr>;

  public type IDs = RBTree.Type<Nat, ()>;
  public type Token = {
    #ICRC2 : Principal;
    // #BTC
    // #ETH
  };

  public type SubaccountMap = {
    subaccount_id : Nat;
    owners : IDs;
  };
  public type Balance = {
    available : Nat;
    locked : Nat;
  };
  public type Subaccount = {
    balances : RBTree.Type<Nat, Balance>;
  };
  public type User = {
    last_activity : Nat64; // for trimming
    subaccounts : RBTree.Type<Nat, Subaccount>;
  };
  public type ICRCDedupes = RBTree.Type<(caller : Nat, ICRCTokenArg), Nat>;
};
