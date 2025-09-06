import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ID "../util/motoko/ID";

module {
  public let AVAILABLE = "orderbook:available";
  public let MAX_ORDER_BATCH = "orderbook:max_order_batch_size";

  public let SELL_TOKEN_ID = "icrc1_icrc1_orderbook:sell_canister_id";
  public let BUY_TOKEN_ID = "icrc1_icrc1_orderbook:buy_canister_id";

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

  public let PLACE_FEE_QUOTE = "orderbook:place_fee_quote";
  public let PLACE_FEE_BASE = "orderbook:place_fee_base";
  public let CANCEL_FEE_QUOTE = "orderbook:cancel_fee_quote";
  public let CANCEL_FEE_BASE = "orderbook:cancel_fee_base";
  // todo: not all need "icrc1_icrc1_" prefix
  public let TX_WINDOW = "orderbook:tx_window";
  public let PERMITTED_DRIFT = "orderbook:permitted_drift";

  public let MIN_MEMO = "orderbook:min_memo_size";
  public let MAX_MEMO = "orderbook:max_memo_size";

  public type Expiries = RBTree.Type<Nat64, ID.Many<()>>;
  public type Amount = { initial : Nat; locked : Nat; filled : Nat };
  public type Price = { base : Amount; orders : ID.Many<()> };
  public type Book = RBTree.Type<(price : Nat), Price>;
  public type Trade = {
    maker : { order : Nat };
    taker : { order : Nat };
  };
  public type OrderClosed = {
    at : Nat64;
    reason : {
      #Filled;
      #Expired;
      #Canceled;
      #Failed : { trade : Nat };
    };
  };
  public type Order = {
    created_at : Nat64;
    owner : Nat;
    subaccount : Nat;
    is_buy : Bool;
    price : Nat;
    base : Amount; // in sell unit
    expires_at : Nat;
    trades : ID.Many<()>;
    closed : ?OrderClosed;
  };
  public type SubaccountMap = {
    id : Nat;
    owners : ID.Many<()>;
  };
  public type Subaccount = {
    orders : ID.Many<()>;
    // note: cant place order on same price
    sells : RBTree.Type<(price : Nat), (order : Nat)>;
    base : Amount;
    buys : RBTree.Type<(price : Nat), (order : Nat)>;
    quote : Amount;
    trades : ID.Many<()>;
  };
  public type User = {
    id : Nat;
    subaccs : ID.Many<Subaccount>;
  };
  public type Users = RBTree.Type<Principal, User>;
  type OrderArg = {
    price : Nat;
    amount : Nat;
    is_buy : Bool;
    expires_at : ?Nat64;
  };
  // todo: use base/quote terms
  type Fee = {
    is_base : Bool;
    amount : ?Nat;
  };
  public type PlaceArg = {
    subaccount : ?Blob;
    orders : [OrderArg];
    fee : ?Fee; // if undefined, dex could use dex token
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
    #OverlappedOrders : { sell_index : Nat; buy_index : Nat };
    #PriceTooHigh : { index : Nat; maximum_price : Nat };
    #PriceTooLow : { index : Nat; minimum_price : Nat };
    #PriceUnavailable : { index : Nat; order_id : Nat };
    #BadFee : { expected_fee : Nat };
  };
  public type PlaceRes = Result.Type<[(order_id : Nat)], PlaceErr>;

  public type ArgType = {
    #Place : PlaceArg;
    // #Cancel : ();
  };
  public type PlaceDedupes = RBTree.Type<(Principal, PlaceArg), Nat>;

};
