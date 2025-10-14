import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Token "../icrc1_canister/Types";

module {
  public let AVAILABLE = "vault:available";
  public let MIN_MEMO = "vault:min_memo_size";
  public let MAX_MEMO = "vault:max_memo_size";
  public let TX_WINDOW = "vault:tx_window";
  public let PERMITTED_DRIFT = "vault:permitted_drift";
  public let FEE_COLLECTOR = "vault:fee_collector";
  public let DEFAULT_TAKE = "vault:default_take_value";
  public let MAX_TAKE = "vault:max_take_value";
  public let MAX_QUERY_BATCH = "vault:max_query_batch_size";

  public type TokenArg = {
    subaccount : ?Blob;
    canister_id : Principal;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at : ?Nat64;
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
    #EmptyInstructions : { block_index : Nat };
    #ZeroAmount : { block_index : Nat; instruction_index : Nat };
    #InvalidAccount : { block_index : Nat; instruction_index : Nat };
    #UnlistedToken : { block_index : Nat; instruction_index : Nat };
    #InsufficientBalance : {
      block_index : Nat;
      instruction_index : Nat;
      balance : Nat;
    };
    #InvalidRecipient : { block_index : Nat; instruction_index : Nat };
    #InvalidTransfer : { block_index : Nat; instruction_index : Nat };
  };
  public type ExecuteRes = Result.Type<[Nat], ExecuteErr>;
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
