import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ID "../util/motoko/ID";
import W "../wallet_canister/Types";
import Value "../util/motoko/Value";
import Account "../util/motoko/ICRC-1/Account";

module {
  public let AVAILABLE = "orderbook:available";
  public let MAX_ORDER_BATCH = "orderbook:max_order_batch_size";

  public let WALLET = "orderbook:wallet_canister_id";
  public let BASE_TOKEN = "icrc1_icrc1_orderbook:base_canister_id";
  public let QUOTE_TOKEN = "icrc1_icrc1_orderbook:quote_canister_id";

  public let AMOUNT_TICK = "orderbook:amount_tick";
  public let PRICE_TICK = "orderbook:price_tick";
  public let MAKER_FEE_NUMER = "orderbook:maker_fee_numerator";
  public let TAKER_FEE_NUMER = "orderbook:taker_fee_numerator";
  public let TRADING_FEE_DENOM = "orderbook:trading_fee_denominator";
  public let MIN_QUOTE_AMOUNT = "orderbook:minimum_quote_amount";
  public let MIN_BASE_AMOUNT = "orderbook:minimum_base_amount";
  public let MIN_PRICE = "orderbook:minimum_price";
  public let TTL = "orderbook:time_to_live"; // seconds
  public let DEFAULT_ORDER_EXPIRY = "orderbook:default_order_expiry";
  public let MAX_ORDER_EXPIRY = "orderbook:max_order_expiry";
  public let MIN_ORDER_EXPIRY = "orderbook:min_order_expiry";

  public let PLACE_FEE_QUOTE = "orderbook:open_fee_quote";
  public let PLACE_FEE_BASE = "orderbook:open_fee_base";
  public let CANCEL_FEE_QUOTE = "orderbook:close_fee_quote";
  public let CANCEL_FEE_BASE = "orderbook:close_fee_base";
  // todo: not all need "icrc1_icrc1_" prefix
  public let TX_WINDOW = "orderbook:tx_window";
  public let PERMITTED_DRIFT = "orderbook:permitted_drift";

  public let MIN_MEMO = "orderbook:min_memo_size";
  public let MAX_MEMO = "orderbook:max_memo_size";
  public let FEE_COLLECTOR = "orderbook:fee_collector";

  public type Expiries = RBTree.Type<Nat64, ID.Many<()>>;
  public type Amount = { initial : Nat; locked : Nat; filled : Nat };
  public type Price = { base : Amount; orders : ID.Many<()> };
  public type Book = RBTree.Type<(price : Nat), Price>;
  public type Trade = {
    sell : { id : Nat; base : Nat; fee_quote : Nat };
    buy : { id : Nat; quote : Nat; fee_base : Nat };
    at : Nat64;
    price : Nat;
    proof : Nat;
  };
  public type OrderClosed = {
    at : Nat64;
    proof : ?Nat;
    reason : {
      #Filled;
      #Expired;
      #Canceled;
    };
  };
  public type Order = {
    is_buy : Bool;
    price : Nat;
    closed : ?OrderClosed;
    expires_at : Nat64;
    base : Amount; // in sell unit
    owner : Principal;
    subaccount : ?Blob;
    created_at : Nat64;
    trades : ID.Many<()>;
  };
  public type Subaccount = {
    orders : ID.Many<()>;
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
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #Duplicate : { duplicate_of : Nat };
    #ExecutionFailed : { instructions : [W.Instruction]; error : W.ExecuteErr };
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
    #ExecutionFailed : { instructions : [W.Instruction]; error : W.ExecuteErr };
  };
  public type CancelRes = Result.Type<Nat, CancelErr>;

  public type RunArg = { subaccount : ?Blob };
  public type RunErr = {
    #GenericError : Error.Type;
    #TradeFailed : {
      buy : Nat;
      sell : Nat;
      instructions : [W.Instruction];
      error : W.ExecuteErr;
    };
    #CloseFailed : {
      order : Nat;
      instructions : [W.Instruction];
      error : W.ExecuteErr;
    };
  };
  public type RunRes = Result.Type<Nat, RunErr>;

  public type Environment = {
    meta : Value.Metadata;
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
