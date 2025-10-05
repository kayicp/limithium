import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import V "../vault_canister/Types";
import Vault "../vault_canister/main";
import Value "../util/motoko/Value";

module {
  public let AVAILABLE = "book:available";
  public let MAX_ORDER_BATCH = "book:max_order_batch_size";

  public let VAULT = "book:wallet_canister_id";
  public let BASE_TOKEN = "book:base_token_id";
  public let QUOTE_TOKEN = "book:quote_token_id";

  public let AMOUNT_TICK = "book:amount_tick";
  public let PRICE_TICK = "book:price_tick";
  public let MAKER_FEE_NUMER = "book:maker_fee_numerator";
  public let TAKER_FEE_NUMER = "book:taker_fee_numerator";
  public let TRADING_FEE_DENOM = "book:trading_fee_denominator";
  public let MIN_QUOTE_AMOUNT = "book:minimum_quote_amount";
  public let MIN_BASE_AMOUNT = "book:minimum_base_amount";
  public let MIN_PRICE = "book:minimum_price";
  public let TTL = "book:time_to_live"; // seconds
  public let DEFAULT_ORDER_EXPIRY = "book:default_order_expiry";
  public let MAX_ORDER_EXPIRY = "book:max_order_expiry";
  public let MIN_ORDER_EXPIRY = "book:min_order_expiry";

  public let PLACE_FEE_QUOTE = "book:open_fee_quote";
  public let PLACE_FEE_BASE = "book:open_fee_base";
  public let CANCEL_FEE_QUOTE = "book:close_fee_quote";
  public let CANCEL_FEE_BASE = "book:close_fee_base";
  // todo: not all need "icrc1_icrc1_" prefix
  public let TX_WINDOW = "book:tx_window";
  public let PERMITTED_DRIFT = "book:permitted_drift";

  public let MIN_MEMO = "book:min_memo_size";
  public let MAX_MEMO = "book:max_memo_size";
  public let FEE_COLLECTOR = "book:fee_collector";

  // todo: add `block_id` to order and trade object
  public type Nats = RBTree.Type<Nat, ()>;
  public type Expiries = RBTree.Type<Nat64, Nats>;
  public type Amount = { initial : Nat; locked : Nat; filled : Nat };
  public type Price = { base : Amount; orders : Nats };
  public type Book = RBTree.Type<(price : Nat), Price>;
  public type Trade = {
    sell : { id : Nat; base : Nat; fee_quote : Nat };
    buy : { id : Nat; quote : Nat; fee_base : Nat };
    at : Nat64;
    price : Nat;
    proof : Nat;
  };
  public type CloseReason = {
    #Filled;
    #Expired;
    #Canceled;
  };
  public type OrderClosed = {
    at : Nat64;
    proof : ?Nat;
    reason : CloseReason;
  };
  public type Order = {
    is_buy : Bool;
    price : Nat;
    closed : ?OrderClosed;
    expires_at : Nat64;
    base : Amount; // in sell unit
    owner : Principal;
    sub : Blob;
    created_at : Nat64;
    proof : Nat;
    trades : Nats;
  };
  public type Subaccount = {
    orders : Nats;
    // note: cant place order on same price
    sells : RBTree.Type<(price : Nat), (order : Nat)>;
    base : Amount;
    buys : RBTree.Type<(price : Nat), (order : Nat)>;
    quote : Amount;
  };
  public type User = {
    subaccs : RBTree.Type<Blob, Subaccount>;
  };
  public type Users = RBTree.Type<Principal, User>;
  type OrderArg = {
    price : Nat;
    amount : Nat;
    is_buy : Bool;
    expires_at : ?Nat64;
  };
  type Fee = {
    base : Nat;
    quote : Nat;
  };
  public type PlaceArg = {
    subaccount : ?Blob;
    orders : [OrderArg];
    fee : ?Fee;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type PlaceErr = {
    #GenericError : Error.Type;
    #BatchTooLarge : { batch_size : Nat; maximum_batch_size : Nat };
    #ExpiresTooSoon : { index : Nat; minimum_expires_at : Nat64 };
    #ExpiresTooLate : { index : Nat; maximum_expires_at : Nat64 };
    #AmountTooLow : { index : Nat; minimum_amount : Nat };
    #PriceTooFar : { index : Nat; nearest_price : Nat };
    #AmountTooFar : { index : Nat; nearest_amount : Nat };
    #DuplicatePrice : { indexes : [Nat] };
    #PriceOverlap : { sell_index : Nat; buy_index : Nat };
    #PriceTooHigh : { index : Nat; maximum_price : Nat };
    #PriceTooLow : { index : Nat; minimum_price : Nat };
    #PriceUnavailable : { index : Nat; order_id : Nat };
    #BadFee : { expected_base : Nat; expected_quote : Nat };
    #InsufficientBalance : { base_balance : Nat; quote_balance : Nat };
    #CreatedInFuture : { vault_time : Nat64 };
    #TooOld;
    #Duplicate : { duplicate_of : Nat };
    #ExecutionFailed : {
      instruction_blocks : [[V.Instruction]];
      error : V.ExecuteErr;
    };
  };
  public type PlaceRes = Result.Type<[(order_id : Nat)], PlaceErr>;

  public type CancelArg = {
    subaccount : ?Blob;
    orders : [Nat];
    fee : ?Fee;
    memo : ?Blob;
  };
  public type CancelErr = {
    #GenericError : Error.Type;
    #BatchTooLarge : { batch_size : Nat; maximum_batch_size : Nat };
    #Duplicate : { indexes : [Nat] };
    #Unauthorized : { index : Nat };
    #NotFound : { index : Nat };
    #Closed : { index : Nat; at : Nat64 };
    #Locked : { index : Nat };
    #BadFee : { expected_base : Nat; expected_quote : Nat };
    #ExecutionFailed : {
      instruction_blocks : [[V.Instruction]];
      error : V.ExecuteErr;
    };
  };
  public type CancelRes = Result.Type<Nat, CancelErr>;

  public type RunArg = { subaccount : ?Blob };
  public type RunErr = {
    #GenericError : Error.Type;
    #TradeFailed : {
      buy : Nat;
      sell : Nat;
      instruction_blocks : [[V.Instruction]];
      error : V.ExecuteErr;
    };
    #CloseFailed : {
      order : Nat;
      instruction_blocks : [[V.Instruction]];
      error : V.ExecuteErr;
    };
    #CorruptOrderBook : { max_book : ?Nat; max_order : Nat };
    #MatchFailed;
  };
  public type RunRes = Result.Type<Nat, RunErr>;

  public type Environment = {
    meta : Value.Metadata;
    vault : Vault.Canister;
    amount_tick : Nat;
    base_token_id : Principal;
    default_expires_at : Nat64;
    fee_denom : Nat;
    maker_fee_numer : Nat;
    max_expires_at : Nat64;
    min_base_amount : Nat;
    min_expires_at : Nat64;
    min_price : Nat;
    min_quote_amount : Nat;
    price_tick : Nat;
    quote_token_id : Principal;
    taker_fee_numer : Nat;
    now : Nat64;
    ttl : Nat64;
  };

  public type ArgType = {
    #Place : PlaceArg;
    // #Cancel : ();
  };
  public type PlaceDedupes = RBTree.Type<(Principal, PlaceArg), Nat>;

};
