import O "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ID "../util/motoko/ID";
import Order "mo:base/Order";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import ICRC1Token "../util/motoko/ICRC-1/Types";
import Time64 "../util/motoko/Time64";

module {
  public func newAmount(initial : Nat) : O.Amount = {
    initial;
    locked = 0;
    filled = 0;
  };
  public func getSubaccount(u : O.User, subacc_id : Blob) : O.Subaccount = switch (RBTree.get(u.subaccs, Blob.compare, subacc_id)) {
    case (?found) found;
    case _ ({
      orders = ID.empty();
      sells = RBTree.empty();
      base = newAmount(0);
      buys = RBTree.empty();
      quote = newAmount(0);
      trades = ID.empty();
    });
  };
  public func saveSubaccount(u : O.User, subacc_id : Blob, subacc : O.Subaccount) : O.User = ({
    u with subaccs = RBTree.insert(u.subaccs, Blob.compare, subacc_id, subacc)
  });
  public func dedupePlace(a : (Principal, O.PlaceArg), b : (Principal, O.PlaceArg)) : Order.Order = #equal; // todo: finish, start with time

  public func nearTick(n : Nat, tick : Nat) : Nat {
    let lower = (n / tick) * tick;
    let upper = lower + tick;
    if (n - lower <= upper - n) lower else upper;
  };
  public func incAmount(a : O.Amount, b : O.Amount) : O.Amount = {
    initial = a.initial + b.initial;
    filled = a.filled + b.filled;
    locked = a.locked + b.locked;
  };
  public func decAmount(a : O.Amount, b : O.Amount) : O.Amount = {
    initial = a.initial - b.initial;
    filled = a.filled - b.filled;
    locked = a.locked - b.locked;
  };
  public func mulAmount(a : O.Amount, b : Nat) : O.Amount = {
    initial = a.initial * b;
    filled = a.filled * b;
    locked = a.locked * b;
  };
  public func lockAmount(a : O.Amount, b : Nat) : O.Amount = {
    a with locked = a.locked + b
  };
  public func unlockAmount(a : O.Amount, b : Nat) : O.Amount = {
    a with locked = if (a.locked > b) a.locked - b else 0
  };
  public func fillAmount(a : O.Amount, b : Nat) : O.Amount = {
    a with filled = a.filled + b
  };
  public func newOrder(now : Nat64, { owner : Principal; subaccount : ?Blob; is_buy : Bool; price : Nat; amount : Nat; expires_at : Nat64 }) : O.Order = {
    created_at = now;
    owner;
    subaccount;
    is_buy;
    price;
    base = newAmount(amount);
    expires_at;
    trades = ID.empty();
    closed = null;
  };
  public func getPrice(book : O.Book, price : Nat) : O.Price = switch (RBTree.get(book, Nat.compare, price)) {
    case (?found) found;
    case _ ({
      base = newAmount(0);
      orders = RBTree.empty();
    });
  };
  public func priceNewOrder(p : O.Price, oid : Nat, o : O.Order) : O.Price = ({
    base = incAmount(p.base, o.base);
    orders = ID.insert(p.orders, oid, ());
  });
  public func priceLock(p : O.Price, l : Nat) : O.Price = ({
    p with base = lockAmount(p.base, l)
  });
  public func priceUnlock(p : O.Price, l : Nat) : O.Price = ({
    p with base = unlockAmount(p.base, l)
  });
  public func priceFill(p : O.Price, l : Nat) : O.Price = ({
    p with base = fillAmount(p.base, l)
  });
  public func savePrice(b : O.Book, price : Nat, p : O.Price) : O.Book = if (RBTree.size(p.orders) > 0) {
    RBTree.insert(b, Nat.compare, price, p);
  } else RBTree.delete(b, Nat.compare, price);

  public func subaccNewSell(s : O.Subaccount, oid : Nat, o : O.Order) : O.Subaccount = ({
    s with orders = ID.insert(s.orders, oid, ());
    sells = RBTree.insert(s.sells, Nat.compare, o.price, oid);
    base = incAmount(s.base, o.base);
  });

  public func subaccNewBuy(s : O.Subaccount, oid : Nat, o : O.Order) : O.Subaccount = ({
    s with orders = ID.insert(s.orders, oid, ());
    buys = RBTree.insert(s.buys, Nat.compare, o.price, oid);
    quote = incAmount(s.quote, mulAmount(o.base, o.price));
  });

  public func subaccLockQuote(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with quote = lockAmount(s.quote, n)
  };
  public func subaccLockBase(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with base = lockAmount(s.base, n);
  };
  public func subaccUnlockQuote(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with quote = unlockAmount(s.quote, n)
  };
  public func subaccUnlockBase(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with base = unlockAmount(s.base, n);
  };
  public func subaccFillQuote(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with quote = fillAmount(s.quote, n)
  };
  public func subaccFillBase(s : O.Subaccount, n : Nat) : O.Subaccount = {
    s with base = fillAmount(s.base, n);
  };
  public func fillOrder(o : O.Order, amount : Nat, trade_id : Nat) : O.Order = {
    o with base = fillAmount(o.base, amount);
    trades = RBTree.insert(o.trades, Nat.compare, trade_id, ());
  };

  public func getExpiries(e : O.Expiries, t : Nat64) : ID.Many<()> = switch (RBTree.get(e, Nat64.compare, t)) {
    case (?found) found;
    case _ RBTree.empty();
  };

  public func saveExpiries(e : O.Expiries, t : Nat64, ids : ID.Many<()>) : O.Expiries = if (RBTree.size(ids) > 0) {
    RBTree.insert(e, Nat64.compare, t, ids);
  } else RBTree.delete(e, Nat64.compare, t);

  public func getEnvironment(_meta : Value.Metadata) : async* Result.Type<O.Environment, Error.Generic> {
    var meta = _meta;
    let base_token_id = switch (Value.metaPrincipal(meta, O.BASE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.BASE_TOKEN # "` is not properly set");
    };
    let quote_token_id = switch (Value.metaPrincipal(meta, O.QUOTE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.QUOTE_TOKEN # "` is not properly set");
    };
    if (base_token_id == quote_token_id) return Error.text("Base token and Quote token are similar");
    let (base_token, quote_token) = (ICRC1Token.genActor(base_token_id), ICRC1Token.genActor(quote_token_id));

    let (base_decimals_res, quote_decimals_res, base_fee_res, quote_fee_res) = (base_token.icrc1_decimals(), quote_token.icrc1_decimals(), base_token.icrc1_fee(), quote_token.icrc1_fee());
    let (base_power, quote_power, base_token_fee, quote_token_fee) = (10 ** Nat8.toNat(await base_decimals_res), 10 ** Nat8.toNat(await quote_decimals_res), await base_fee_res, await quote_fee_res);

    var amount_tick = Value.getNat(meta, O.AMOUNT_TICK, 0);
    if (amount_tick < base_token_fee) {
      amount_tick := base_token_fee;
      meta := Value.setNat(meta, O.AMOUNT_TICK, ?amount_tick);
    };
    var price_tick = Value.getNat(meta, O.PRICE_TICK, 0);
    if (price_tick < quote_token_fee) {
      price_tick := quote_token_fee;
      meta := Value.setNat(meta, O.PRICE_TICK, ?price_tick);
    };
    var fee_denom = Value.getNat(meta, O.TRADING_FEE_DENOM, 0);
    if (fee_denom < 100) {
      fee_denom := 100;
      meta := Value.setNat(meta, O.TRADING_FEE_DENOM, ?fee_denom);
    };
    var maker_fee_numer = Value.getNat(meta, O.MAKER_FEE_NUMER, 0);
    let max_fee_denom = fee_denom / 10; // max at most 10%
    if (maker_fee_numer > max_fee_denom) {
      maker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, O.MAKER_FEE_NUMER, ?maker_fee_numer);
    };
    var taker_fee_numer = Value.getNat(meta, O.TAKER_FEE_NUMER, 0);
    if (taker_fee_numer > max_fee_denom) {
      taker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, O.TAKER_FEE_NUMER, ?taker_fee_numer);
    };
    let min_fee_numer = Nat.max(1, Nat.min(maker_fee_numer, taker_fee_numer));
    // todo: rethink?
    // (tokenfee * 2) for amount + future transfer of amount
    let lowest_base_amount = base_token_fee * 2 * fee_denom / min_fee_numer;
    var min_base_amount = Value.getNat(meta, O.MIN_BASE_AMOUNT, 0);
    if (min_base_amount < lowest_base_amount) {
      min_base_amount := lowest_base_amount;
      meta := Value.setNat(meta, O.MIN_BASE_AMOUNT, ?min_base_amount);
    };
    let lowest_quote_amount = quote_token_fee * 2 * fee_denom / min_fee_numer;
    var min_quote_amount = Value.getNat(meta, O.MIN_QUOTE_AMOUNT, 0);
    if (min_quote_amount < lowest_quote_amount) {
      min_quote_amount := lowest_quote_amount;
      meta := Value.setNat(meta, O.MIN_QUOTE_AMOUNT, ?min_quote_amount);
    };
    let lowest_price = min_quote_amount / min_base_amount;
    var min_price = Value.getNat(meta, O.MIN_PRICE, 0);
    if (min_price < lowest_price) {
      min_price := lowest_price;
      meta := Value.setNat(meta, O.MIN_PRICE, ?min_price);
    };
    var max_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.MAX_ORDER_EXPIRY, 0)));
    let lowest_max_expiry = Time64.HOURS(24);
    let highest_max_expiry = lowest_max_expiry * 30;
    if (max_expiry < lowest_max_expiry) {
      max_expiry := lowest_max_expiry;
      meta := Value.setNat(meta, O.MAX_ORDER_EXPIRY, ?(Nat64.toNat(lowest_max_expiry / 1_000_000_000)));
    } else if (max_expiry > highest_max_expiry) {
      max_expiry := highest_max_expiry;
      meta := Value.setNat(meta, O.MAX_ORDER_EXPIRY, ?(Nat64.toNat(highest_max_expiry / 1_000_000_000)));
    };
    var min_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.MIN_ORDER_EXPIRY, 0)));
    let lowest_min_expiry = Time64.HOURS(1);
    let max_expiry_seconds = Nat64.toNat(max_expiry / 1_000_000_000);
    if (min_expiry < lowest_min_expiry) {
      min_expiry := lowest_min_expiry;
      meta := Value.setNat(meta, O.MIN_ORDER_EXPIRY, ?(Nat64.toNat(min_expiry / 1_000_000_000)));
    } else if (min_expiry > max_expiry) {
      min_expiry := max_expiry;
      meta := Value.setNat(meta, O.DEFAULT_ORDER_EXPIRY, ?max_expiry_seconds);
    };
    var default_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.DEFAULT_ORDER_EXPIRY, 0)));
    if (default_expiry < min_expiry or default_expiry > max_expiry) {
      default_expiry := (min_expiry + max_expiry) / 2;
      meta := Value.setNat(meta, O.DEFAULT_ORDER_EXPIRY, ?(Nat64.toNat(default_expiry / 1_000_000_000)));
    };
    let min_ttl = Time64.DAYS(1);
    var ttl = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.TTL, 0)));
    if (ttl < min_ttl) {
      ttl := min_ttl;
      meta := Value.setNat(meta, O.TTL, ?86400);
    };
    let now = Time64.nanos();
    #Ok {
      meta;
      base_token_id;
      quote_token_id;
      amount_tick;
      price_tick;
      fee_denom;
      maker_fee_numer;
      taker_fee_numer;
      min_base_amount;
      min_quote_amount;
      min_price;
      max_expires_at = now + max_expiry;
      min_expires_at = now + min_expiry;
      default_expires_at = now + default_expiry;
      now;
      ttl;
    };
  };
};
