import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ICRC1Token "../icrc1_canister/Types";
import ID "../util/motoko/ID";

module {
  public let AVAILABLE = "wallet:available";
  public let MIN_MEMO = "wallet:min_memo_size";
  public let MAX_MEMO = "wallet:max_memo_size";
  public let TX_WINDOW = "wallet:tx_window";
  public let PERMITTED_DRIFT = "wallet:permitted_drift";
  public let FEE_COLLECTOR = "wallet:fee_collector";

  public type ICRC1TokenArg = {
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
    #TransferFailed : ICRC1Token.TransferFromError;
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
    #TransferFailed : ICRC1Token.TransferError;
  };
  public type WithdrawRes = Result.Type<Nat, WithdrawErr>;

  public type Balance = {
    unlocked : Nat;
    locked : Nat;
  };
  public type Subaccount = {
    icrc1s : RBTree.Type<Principal, Balance>;
  };
  public type User = {
    last_activity : Nat64; // for trimming
    subaccs : RBTree.Type<Blob, Subaccount>;
  };
  public type Users = RBTree.Type<Principal, User>;
  public type ICRCDedupes = RBTree.Type<(Principal, ICRC1TokenArg), Nat>;

  public type ArgType = {
    #DepositICRC : ICRC1TokenArg;
    #WithdrawICRC : ICRC1TokenArg;
  };
  public type ICRC1Token = {
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };
  public type Asset = {
    #ICRC1 : { canister_id : Principal };
    // #BTC;
    // #ETH;
    // #ERC20 : { contract_address: Text };
  };
  public type Action = {
    // todo: move amount to Instruction
    #Lock;
    #Unlock;
    #Transfer : { to : ICRC1Token.Account };
  };
  public type ExecuteErr = {
    #GenericError : Error.Type;
    #UnlistedAsset : { index : Nat };
    #InsufficientBalance : { index : Nat; balance : Nat };
    #InvalidTransfer : { index : Nat };
    #ZeroAmount : { index : Nat };
  };
  public type ExecuteRes = Result.Type<Nat, ExecuteErr>;
  public type Instruction = {
    account : ICRC1Token.Account;
    asset : Asset;
    amount : Nat;
    action : Action;
  };
  public type UserData = {
    owner : Principal;
    user : User;
    subacc : Blob;
    subacc_data : Subaccount;
  };
};
