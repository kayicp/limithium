import Principal "mo:base/Principal";
import Error "../util/motoko/Error";
import Result "../util/motoko/Result";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";

module {
  public let default_subaccount : [Nat8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  public type Account = { owner : Principal; subaccount : ?Blob };
  public type AllowanceTuple = (allowance : Nat, expiry : ?Nat64);
  public type SpenderSubs = RBTree.Type<Blob, AllowanceTuple>;
  public type Subaccount = (balance : Nat, spenders : RBTree.Type<Principal, SpenderSubs>);
  public type Subaccounts = RBTree.Type<Blob, Subaccount>;
  public type Users = RBTree.Type<Principal, Subaccounts>;

  public type TransferError = {
    #GenericError : Error.Type;
    #TemporarilyUnavailable;
    #BadBurn : { min_burn_amount : Nat };
    #Duplicate : { duplicate_of : Nat };
    #BadFee : { expected_fee : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #InsufficientFunds : { balance : Nat };
  };

  public type TransferArg = {
    to : Account;
    fee : ?Nat;
    memo : ?Blob;
    from_subaccount : ?Blob;
    created_at_time : ?Nat64;
    amount : Nat;
  };

  public type TransferFromArg = {
    to : Account;
    fee : ?Nat;
    spender_subaccount : ?Blob;
    from : Account;
    memo : ?Blob;
    created_at_time : ?Nat64;
    amount : Nat;
  };

  public type TransferFromError = {
    #GenericError : Error.Type;
    #TemporarilyUnavailable;
    #InsufficientAllowance : { allowance : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #Duplicate : { duplicate_of : Nat };
    #BadFee : { expected_fee : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #InsufficientFunds : { balance : Nat };
  };

  public type ApproveArg = {
    fee : ?Nat;
    memo : ?Blob;
    from_subaccount : ?Blob;
    created_at_time : ?Nat64;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    spender : Account;
  };

  public type ApproveError = {
    #GenericError : Error.Type;
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #BadFee : { expected_fee : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #Expired : { ledger_time : Nat64 };
    #InsufficientFunds : { balance : Nat };
  };

  public type AllowanceArg = { account : Account; spender : Account };
  public type Allowance = { allowance : Nat; expires_at : ?Nat64 };
  public type GetBlocksRequest = { start : Nat; length : Nat };
  public type GetBlocksResult = {
    log_length : Nat;
    blocks : [BlockWithId];
    archived_blocks : [ArchivedBlocks];
  };
  public type BlockWithId = { id : Nat; block : Value.Type };
  public type ArchivedBlocks = {
    args : [GetBlocksRequest];
    callback : shared query [GetBlocksRequest] -> async GetBlocksResult;
  };

  public type EnqueueErrors = {

  };
};
