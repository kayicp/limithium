import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Order "mo:base/Order";
import ICRCToken "../util/motoko/ICRC-1/Types";

module {

  public let MIN_MEMO = "wallet:min_memo_size";
  public let MAX_MEMO = "wallet:max_memo_size";
  public let TX_WINDOW = "wallet:tx_window";
  public let PERMITTED_DRIFT = "wallet:permitted_drift";

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
    #AmountTooLow : { minimum_amount : Nat };
    #BadFee : { expected_fee : Nat };
    #InsufficientBalance : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #Duplicate : { duplicate_of : Nat };
    #TransferFailed : ICRCToken.TransferFromError;
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
  public type SubaccountMap = {
    id : Nat;
    owners : IDs;
  };
  public type Balance = {
    unlocked : Nat;
    locked : Nat;
  };
  public type Subaccount = {
    icrc2s : RBTree.Type<Nat, Balance>;
  };
  public type User = {
    id : Nat;
    last_activity : Nat64; // for trimming
    subaccounts : RBTree.Type<Nat, Subaccount>;
  };
  public type Users = RBTree.Type<Principal, User>;
  public type ICRCDedupes = RBTree.Type<(Principal, ICRCTokenArg), Nat>;
  public func dedupeICRC(a : (Principal, ICRCTokenArg), b : (Principal, ICRCTokenArg)) : Order.Order = #equal; // todo: finish this, start with time;

  public type GenericRes = Result.Type<(), Error.Generic>;
  public type ICRCToken = {
    id : Nat;
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };
};
