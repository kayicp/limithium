import Principal "mo:base/Principal";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";

module {
  public let NAME = "icrc1:name";
  public let SYMBOL = "icrc1:symbol";
  public let DECIMALS = "icrc1:decimals";
  public let MAX_SUPPLY = "icrc1:max_supply";
  public let LOGO = "icrc1:logo";
  public let TX_WINDOW = "icrc1:tx_window";
  public let PERMITTED_DRIFT = "icrc1:permitted_drift";
  public let MINTER = "icrc1:minter";
  public let TOTAL_SUPPLY = "icrc1:total_supply";
  public let FEE = "icrc1:fee";
  public let MIN_MEMO = "icrc1:min_memo_size";
  public let MAX_MEMO = "icrc1:max_memo_size";
  public let MAX_APPROVAL_EXPIRY = "icrc1:max_approval_expiry";
  public let MIN_APPROVAL_EXPIRY = "icrc1:min_approval_expiry";
  public let AVAILABLE = "xlt:available";
  public let VAULT = "xlt:vault";
  public let MAX_UPDATE_BATCH = "xlt:max_update_batch_size";
  public let MAX_MINT = "xlt:max_mint_per_round";

  public type Account = { owner : Principal; subaccount : ?Blob };
  public type Approval = { allowance : Nat; expires_at : Nat64 };
  public type Approvals = RBTree.Type<Blob, Approval>;
  public type Subaccount = {
    balance : Nat;
    spenders : RBTree.Type<Principal, Approvals>;
  };
  public type Subaccounts = RBTree.Type<Blob, Subaccount>;
  public type Users = RBTree.Type<Principal, Subaccounts>;
  public type Expiries = RBTree.Type<Nat64, RBTree.Type<Principal, RBTree.Type<Blob, RBTree.Type<Principal, RBTree.Type<Blob, ()>>>>>;

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

  public type ArgType = {
    #Transfer : TransferArg;
    #Approve : ApproveArg;
    #TransferFrom : TransferFromArg;
  };

  public type Environment = {
    meta : Value.Metadata;
    minter : Account;
    fee : Nat;
    max_mint : Nat;
    total_supply : Nat;
    now : Nat64;
    dedupe_start : Nat64;
    dedupe_end : Nat64;
  };

  public type Enqueue = { account : Account; rounds : Nat };
  public type EnqueueErrors = {
    #BatchTooLarge : { batch_size : Nat; maximum_batch_size : Nat };
    #GenericError : Error.Type;
  };
};
