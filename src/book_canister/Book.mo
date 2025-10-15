import B "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Order "mo:base/Order";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Blob "mo:base/Blob";
import Bool "mo:base/Bool";
import Nat8 "mo:base/Nat8";
import Iter "mo:base/Iter";
import Principal "mo:base/Principal";
import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import ICRC1 "../icrc1_canister/main";
import Time64 "../util/motoko/Time64";
import Option "../util/motoko/Option";
import Vault "../vault_canister/main";
import Subaccount "../util/motoko/Subaccount";

module {
  public func newAmount(initial : Nat) : B.Amount = {
    initial;
    locked = 0;
    filled = 0;
  };
  public func getSubaccount(u : B.User, subacc_id : Blob) : B.Subaccount = switch (RBTree.get(u.subaccs, Blob.compare, subacc_id)) {
    case (?found) found;
    case _ ({
      orders = RBTree.empty();
      sells = RBTree.empty();
      base = newAmount(0);
      buys = RBTree.empty();
      quote = newAmount(0);
    });
  };
  public func saveSubaccount(u : B.User, subacc_id : Blob, subacc : B.Subaccount) : B.User = ({
    u with subaccs = RBTree.insert(u.subaccs, Blob.compare, subacc_id, subacc)
  });
  public func dedupePlace(_a : (Principal, B.PlaceArg), _b : (Principal, B.PlaceArg)) : Order.Order {
    let (ap, a) = _a;
    let (bp, b) = _b;
    switch (Option.compare(a.created_at, b.created_at, Nat64.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.memo, b.memo, Blob.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (Principal.compare(ap, bp)) {
      case (#equal) ();
      case other return other;
    };
    switch (Blob.compare(Subaccount.get(a.subaccount), Subaccount.get(b.subaccount))) {
      case (#equal) ();
      case other return other;
    };
    switch (a.fee, b.fee) {
      case (?af, ?bf) {
        switch (Nat.compare(af.base, bf.base)) {
          case (#equal) ();
          case other return other;
        };
        switch (Nat.compare(af.quote, bf.quote)) {
          case (#equal) ();
          case other return other;
        };
      };
      case (?af, null) return #greater;
      case (null, ?bf) return #less;
      case (null, null) ();
    };
    switch (Nat.compare(a.orders.size(), b.orders.size())) {
      case (#equal) ();
      case other return other;
    };
    if (a.orders.size() > 0) for (i in Iter.range(0, a.orders.size() - 1)) {
      let ao = a.orders[i];
      let bo = b.orders[i];

      switch (Nat.compare(ao.price, bo.price)) {
        case (#equal) ();
        case other return other;
      };
      switch (Nat.compare(ao.amount, bo.amount)) {
        case (#equal) ();
        case other return other;
      };
      switch (Option.compare(ao.expires_at, bo.expires_at, Nat64.compare)) {
        case (#equal) ();
        case other return other;
      };
      return Bool.compare(ao.is_buy, bo.is_buy);
    };
    #equal;
  };

  public func nearTick(n : Nat, tick : Nat) : Nat {
    let lower = (n / tick) * tick;
    let upper = lower + tick;
    if (n - lower <= upper - n) lower else upper;
  };
  public func incAmount(a : B.Amount, b : B.Amount) : B.Amount = {
    initial = a.initial + b.initial;
    filled = a.filled + b.filled;
    locked = a.locked + b.locked;
  };
  public func decAmount(a : B.Amount, b : B.Amount) : B.Amount = {
    initial = if (a.initial > b.initial) a.initial - b.initial else 0;
    filled = if (a.filled > b.filled) a.filled - b.filled else 0;
    locked = if (a.locked > b.locked) a.locked - b.locked else 0;
  };
  public func mulAmount(a : B.Amount, b : Nat) : B.Amount = {
    initial = a.initial * b;
    filled = a.filled * b;
    locked = a.locked * b;
  };
  public func lockAmount(a : B.Amount, b : Nat) : B.Amount = {
    a with locked = a.locked + b
  };
  public func unlockAmount(a : B.Amount, b : Nat) : B.Amount = {
    a with locked = if (a.locked > b) a.locked - b else 0
  };
  public func fillAmount(a : B.Amount, b : Nat) : B.Amount = {
    a with filled = a.filled + b
  };
  public func newOrder(execute : Nat, block : Nat, now : Nat64, { owner : Principal; sub : Blob; is_buy : Bool; price : Nat; amount : Nat; expires_at : Nat64 }) : B.Order = {
    defaultOrder(owner, sub, is_buy, now) with
    execute;
    block;
    price;
    base = newAmount(amount);
    expires_at;
  };
  public func isClosing(c : B.CloseReason) : Bool = switch c {
    case (#AlmostFilled null or #Expired null or #Canceled null) true;
    case _ false;
  };
  public func getLevel(book : B.Book, price : Nat) : B.Price = switch (RBTree.get(book, Nat.compare, price)) {
    case (?found) found;
    case _ ({
      base = newAmount(0);
      orders = RBTree.empty();
    });
  };
  public func levelNewOrder(p : B.Price, oid : Nat) : B.Price = {
    p with orders = RBTree.insert(p.orders, Nat.compare, oid, ());
  };
  public func levelIncAmount(p : B.Price, o : B.Amount) : B.Price = {
    p with base = incAmount(p.base, o);
  };
  public func levelDelOrder(p : B.Price, oid : Nat) : B.Price = {
    p with orders = RBTree.delete(p.orders, Nat.compare, oid);
  };
  public func levelDecAmount(p : B.Price, o : B.Amount) : B.Price = {
    p with base = decAmount(p.base, o);
  };
  public func levelLock(p : B.Price, l : Nat) : B.Price = ({
    p with base = lockAmount(p.base, l)
  });
  public func levelUnlock(p : B.Price, l : Nat) : B.Price = ({
    p with base = unlockAmount(p.base, l)
  });
  public func levelFill(p : B.Price, l : Nat) : B.Price = ({
    p with base = fillAmount(p.base, l);
  });
  public func saveLevel(b : B.Book, price : Nat, p : B.Price) : B.Book = if (RBTree.size(p.orders) > 0) {
    RBTree.insert(b, Nat.compare, price, p);
  } else RBTree.delete(b, Nat.compare, price);

  public func subaccNewOrder(s : B.Subaccount, oid : Nat) : B.Subaccount = {
    s with orders = RBTree.insert(s.orders, Nat.compare, oid, ())
  };
  public func subaccDelOrder(s : B.Subaccount, oid : Nat) : B.Subaccount = {
    s with orders = RBTree.delete(s.orders, Nat.compare, oid);
  };

  public func subaccNewSell(s : B.Subaccount, oid : Nat, o : B.Order) : B.Subaccount = ({
    s with sells = RBTree.insert(s.sells, Nat.compare, o.price, oid);
  });
  public func subaccNewBuy(s : B.Subaccount, oid : Nat, o : B.Order) : B.Subaccount = ({
    s with buys = RBTree.insert(s.buys, Nat.compare, o.price, oid);
  });
  public func subaccDelSell(s : B.Subaccount, o : B.Order) : B.Subaccount = ({
    s with sells = RBTree.delete(s.sells, Nat.compare, o.price);
  });
  public func subaccDelBuy(s : B.Subaccount, o : B.Order) : B.Subaccount = ({
    s with buys = RBTree.delete(s.buys, Nat.compare, o.price);
  });
  public func subaccIncQuote(s : B.Subaccount, q : B.Amount) : B.Subaccount = {
    s with quote = incAmount(s.quote, q);
  };
  public func subaccIncBase(s : B.Subaccount, b : B.Amount) : B.Subaccount = {
    s with base = incAmount(s.base, b);
  };
  public func subaccDecQuote(s : B.Subaccount, q : B.Amount) : B.Subaccount = {
    s with quote = decAmount(s.quote, q);
  };
  public func subaccDecBase(s : B.Subaccount, b : B.Amount) : B.Subaccount = {
    s with base = decAmount(s.base, b);
  };
  public func subaccLockQuote(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with quote = lockAmount(s.quote, n)
  };
  public func subaccLockBase(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with base = lockAmount(s.base, n);
  };
  public func subaccUnlockQuote(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with quote = unlockAmount(s.quote, n)
  };
  public func subaccUnlockBase(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with base = unlockAmount(s.base, n);
  };
  public func subaccFillQuote(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with quote = fillAmount(s.quote, n)
  };
  public func subaccFillBase(s : B.Subaccount, n : Nat) : B.Subaccount = {
    s with base = fillAmount(s.base, n);
  };
  public func fillOrder(o : B.Order, amount : Nat, trade_id : Nat) : B.Order = {
    o with base = fillAmount(o.base, amount);
    trades = RBTree.insert(o.trades, Nat.compare, trade_id, ());
  };
  public func lockOrder(o : B.Order, amount : Nat) : B.Order = {
    o with base = lockAmount(o.base, amount)
  };
  public func unlockOrder(o : B.Order, amount : Nat) : B.Order = {
    o with base = unlockAmount(o.base, amount)
  };
  public func defaultOrder(owner : Principal, sub : Blob, is_buy : Bool, created_at : Nat64) : B.Order = {
    created_at;
    execute = 0;
    block = 0;
    owner;
    sub;
    is_buy;
    price = 0;
    base = newAmount(0);
    expires_at = 0;
    trades = RBTree.empty();
    closed = null;
  };
  public func getExpiries(e : B.Expiries, t : Nat64) : B.Nats = switch (RBTree.get(e, Nat64.compare, t)) {
    case (?found) found;
    case _ RBTree.empty();
  };
  public func saveExpiries(e : B.Expiries, t : Nat64, ids : B.Nats) : B.Expiries = if (RBTree.size(ids) > 0) {
    RBTree.insert(e, Nat64.compare, t, ids);
  } else RBTree.delete(e, Nat64.compare, t);

  public func newExpiry(exps : B.Expiries, t : Nat64, id : Nat) : B.Expiries {
    var expiries = getExpiries(exps, t);
    expiries := RBTree.insert(expiries, Nat.compare, id, ());
    saveExpiries(exps, t, expiries);
  };
  public func delExpiry(exps : B.Expiries, t : Nat64, id : Nat) : B.Expiries {
    var expiries = getExpiries(exps, t);
    expiries := RBTree.delete(expiries, Nat.compare, id);
    saveExpiries(exps, t, expiries);
  };
  public func valueOpens(owner : Principal, sub : Blob, memo : ?Blob, created_at : ?Nat64, now : Nat64, orders : [Value.Type], phash : ?Blob) : Value.Type {
    let subaccount = if (sub.size() > 0) ?sub else null;
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setAccountP(tx, "acct", ?{ owner; subaccount });
    tx := Value.setBlob(tx, "memo", memo);
    tx := Value.setArray(tx, "orders", orders);
    switch created_at {
      case (?t) tx := Value.setNat(tx, "ts", ?Nat64.toNat(t));
      case _ ();
    };
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setText(map, "op", ?"open");
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };
  public func valueCloses(memo : ?Blob, now : Nat64, orders : [Value.Type], phash : ?Blob) : Value.Type {
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setBlob(tx, "memo", memo);
    tx := Value.setArray(tx, "orders", orders);
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setText(map, "op", ?"close");
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };
  public func valueOpen(order_id : Nat, { price; is_buy; base; expires_at; execute } : B.Order) : Value.Type {
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "id", ?order_id);
    map := Value.setNat(map, "price", ?price);
    map := Value.setText(map, "side", if (is_buy) ?"buy" else ?"sell");
    map := Value.setNat(map, "amt", ?base.initial);
    map := Value.setNat(map, "expires_at", ?Nat64.toNat(expires_at));
    map := Value.setNat(map, "exec", ?execute);
    #Map(RBTree.array(map));
  };
  public func valueClose(order_id : Nat, unlock_key : Text, unlock_amt : Nat, fee : Nat, execute : Nat) : Value.Type {
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "id", ?order_id);
    map := Value.setNat(map, unlock_key, ?unlock_amt);
    if (fee > 0) map := Value.setNat(map, "fee", ?fee);
    map := Value.setNat(map, "exec", ?execute);
    #Map(RBTree.array(map));
  };
  public func valueTrade(trade_id : Nat, now : Nat64, phash : ?Blob, sh : B.SellHand, bh : B.BuyHand) : Value.Type {
    var sell = RBTree.empty<Text, Value.Type>();
    sell := Value.setNat(sell, "id", ?sh.id);
    sell := Value.setNat(sell, "base", ?sh.base);
    sell := Value.setNat(sell, "fee_quote", ?sh.fee_quote);
    sell := Value.setNat(sell, "exec", ?sh.execute);
    sell := Value.setNat(sell, "fee_exec", ?sh.fee_execute);
    var buy = RBTree.empty<Text, Value.Type>();
    buy := Value.setNat(buy, "id", ?bh.id);
    buy := Value.setNat(buy, "quote", ?bh.quote);
    buy := Value.setNat(buy, "fee_base", ?bh.fee_base);
    buy := Value.setNat(buy, "exec", ?bh.execute);
    buy := Value.setNat(buy, "fee_exec", ?bh.fee_execute);
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setNat(tx, "id", ?trade_id);
    tx := Value.setMap(tx, "sell", sell);
    tx := Value.setMap(tx, "buy", buy);
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setText(map, "op", ?"trade");
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };

  public func getEnvironment(_meta : Value.Metadata) : async* Result.Type<B.Environment, Error.Generic> {
    var meta = _meta;
    let vault = switch (Value.metaPrincipal(meta, B.VAULT)) {
      case (?found) actor (Principal.toText(found)) : Vault.Canister;
      case _ return Error.text("Metadata `" # B.VAULT # "` not properly set");
    };
    let base_token_id = switch (Value.metaPrincipal(meta, B.BASE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # B.BASE_TOKEN # "` is not properly set");
    };
    let quote_token_id = switch (Value.metaPrincipal(meta, B.QUOTE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # B.QUOTE_TOKEN # "` is not properly set");
    };
    if (base_token_id == quote_token_id) return Error.text("Base token and Quote token are similar");
    let (base_token, quote_token) = (actor (Principal.toText(base_token_id)) : ICRC1.Canister, actor (Principal.toText(quote_token_id)) : ICRC1.Canister);

    let (base_decimals_res, quote_decimals_res, base_fee_res, quote_fee_res) = (base_token.icrc1_decimals(), quote_token.icrc1_decimals(), base_token.icrc1_fee(), quote_token.icrc1_fee());
    let (base_power, quote_power, base_token_fee, quote_token_fee) = (10 ** Nat8.toNat(await base_decimals_res), 10 ** Nat8.toNat(await quote_decimals_res), await base_fee_res, await quote_fee_res);

    var amount_tick = Value.getNat(meta, B.AMOUNT_TICK, 0);
    if (amount_tick < base_token_fee) {
      amount_tick := base_token_fee;
      meta := Value.setNat(meta, B.AMOUNT_TICK, ?amount_tick);
    };
    var price_tick = Value.getNat(meta, B.PRICE_TICK, 0);
    if (price_tick < quote_token_fee) {
      price_tick := quote_token_fee;
      meta := Value.setNat(meta, B.PRICE_TICK, ?price_tick);
    };
    var fee_denom = Value.getNat(meta, B.TRADING_FEE_DENOM, 0);
    if (fee_denom < 100) {
      fee_denom := 100;
      meta := Value.setNat(meta, B.TRADING_FEE_DENOM, ?fee_denom);
    };
    var maker_fee_numer = Value.getNat(meta, B.MAKER_FEE_NUMER, 0);
    let max_fee_denom = fee_denom / 10; // max at most 10%
    if (maker_fee_numer > max_fee_denom) {
      maker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, B.MAKER_FEE_NUMER, ?maker_fee_numer);
    };
    var taker_fee_numer = Value.getNat(meta, B.TAKER_FEE_NUMER, 0);
    if (taker_fee_numer > max_fee_denom) {
      taker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, B.TAKER_FEE_NUMER, ?taker_fee_numer);
    };
    let min_fee_numer = Nat.max(1, Nat.min(maker_fee_numer, taker_fee_numer));
    // todo: rethink?
    // (tokenfee * 2) for amount + future transfer of amount
    let lowest_base_amount = base_token_fee * 2 * fee_denom / min_fee_numer;
    var min_base_amount = Value.getNat(meta, B.MIN_BASE_AMOUNT, 0);
    if (min_base_amount < lowest_base_amount) {
      min_base_amount := lowest_base_amount;
      meta := Value.setNat(meta, B.MIN_BASE_AMOUNT, ?min_base_amount);
    };
    let lowest_quote_amount = quote_token_fee * 2 * fee_denom / min_fee_numer;
    var min_quote_amount = Value.getNat(meta, B.MIN_QUOTE_AMOUNT, 0);
    if (min_quote_amount < lowest_quote_amount) {
      min_quote_amount := lowest_quote_amount;
      meta := Value.setNat(meta, B.MIN_QUOTE_AMOUNT, ?min_quote_amount);
    };
    let lowest_price = min_quote_amount / min_base_amount;
    var min_price = Value.getNat(meta, B.MIN_PRICE, 0);
    if (min_price < lowest_price) {
      min_price := lowest_price;
      meta := Value.setNat(meta, B.MIN_PRICE, ?min_price);
    };
    var max_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, B.MAX_ORDER_EXPIRY, 0)));
    let lowest_max_expiry = Time64.HOURS(24);
    let highest_max_expiry = lowest_max_expiry * 30;
    if (max_expiry < lowest_max_expiry) {
      max_expiry := lowest_max_expiry;
      meta := Value.setNat(meta, B.MAX_ORDER_EXPIRY, ?(Nat64.toNat(lowest_max_expiry / 1_000_000_000)));
    } else if (max_expiry > highest_max_expiry) {
      max_expiry := highest_max_expiry;
      meta := Value.setNat(meta, B.MAX_ORDER_EXPIRY, ?(Nat64.toNat(highest_max_expiry / 1_000_000_000)));
    };
    var min_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, B.MIN_ORDER_EXPIRY, 0)));
    let lowest_min_expiry = Time64.HOURS(1);
    let max_expiry_seconds = Nat64.toNat(max_expiry / 1_000_000_000);
    if (min_expiry < lowest_min_expiry) {
      min_expiry := lowest_min_expiry;
      meta := Value.setNat(meta, B.MIN_ORDER_EXPIRY, ?(Nat64.toNat(min_expiry / 1_000_000_000)));
    } else if (min_expiry > max_expiry) {
      min_expiry := max_expiry;
      meta := Value.setNat(meta, B.DEFAULT_ORDER_EXPIRY, ?max_expiry_seconds);
    };
    var default_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, B.DEFAULT_ORDER_EXPIRY, 0)));
    if (default_expiry < min_expiry or default_expiry > max_expiry) {
      default_expiry := (min_expiry + max_expiry) / 2;
      meta := Value.setNat(meta, B.DEFAULT_ORDER_EXPIRY, ?(Nat64.toNat(default_expiry / 1_000_000_000)));
    };
    let min_ttl = Time64.DAYS(1);
    var ttl = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, B.TTL, 0)));
    if (ttl < min_ttl) {
      ttl := min_ttl;
      meta := Value.setNat(meta, B.TTL, ?86400);
    };
    let now = Time64.nanos();
    var tx_window = Nat64.fromNat(Value.getNat(meta, B.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, B.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, B.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, B.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    #Ok {
      meta;
      vault;
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
      tx_window;
      permitted_drift;
      ttl;
    };
  };
};
