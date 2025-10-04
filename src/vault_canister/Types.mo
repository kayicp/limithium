import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Token "../icrc1_canister/Types";

module {
  public let AVAILABLE = "wallet:available";
  public let MIN_MEMO = "wallet:min_memo_size";
  public let MAX_MEMO = "wallet:max_memo_size";
  public let TX_WINDOW = "wallet:tx_window";
  public let PERMITTED_DRIFT = "wallet:permitted_drift";
  public let FEE_COLLECTOR = "wallet:fee_collector";

  public type TokenArg = {
    subaccount : ?Blob;
    canister_id : Principal;
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
    #TransferFailed : Token.TransferFromError;
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
    #TransferFailed : Token.TransferError;
  };
  public type WithdrawRes = Result.Type<Nat, WithdrawErr>;

  public type Balance = {
    unlocked : Nat;
    locked : Nat;
  };
  public type Subaccount = RBTree.Type<(canister_id : Principal), Balance>;
  public type User = {
    last_activity : Nat64; // for trimming
    subaccs : RBTree.Type<Blob, Subaccount>;
  };
  public type Users = RBTree.Type<Principal, User>;
  public type Dedupes = RBTree.Type<(Principal, TokenArg), Nat>;

  public type ArgType = {
    #Deposit : TokenArg;
    #Withdraw : TokenArg;
  };
  public type Token = {
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };
  public type Action = {
    // todo: move amount to Instruction
    #Lock;
    #Unlock;
    #Transfer : { to : Token.Account };
  };
  public type ExecuteErr = {
    #GenericError : Error.Type;
    #ZeroAmount : { index : Nat };
    #InvalidAccount : { index : Nat };
    #UnlistedToken : { index : Nat };
    #InsufficientBalance : { index : Nat; balance : Nat };
    #InvalidRecipient : { index : Nat };
    #InvalidTransfer : { index : Nat };
  };
  public type AggregateRes = Result.Type<Nat, ExecuteErr>;
  public type GranularRes = Result.Type<[Nat], ExecuteErr>;
  public type Instruction = {
    account : Token.Account;
    token : Principal;
    amount : Nat;
    action : Action;
  };
  public type Actor = actor {
    vault_is_executor : shared Principal -> async Bool;
  };
};
