import O "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ID "../util/motoko/ID";
import Order "mo:base/Order";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";

module {
  public func newAmount(initial : Nat) : O.Amount = {
    initial;
    locked = 0;
    filled = 0;
  };
  public func getSubaccount(u : O.User, subacc_id : Nat) : O.Subaccount = switch (ID.get(u.subaccs, subacc_id)) {
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
  public func saveSubaccount(u : O.User, subacc_id : Nat, subacc : O.Subaccount) : O.User = ({
    u with subaccs = ID.insert(u.subaccs, subacc_id, subacc)
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
  public func newOrder(now : Nat64, { owner : Nat; subaccount : Nat; is_buy : Bool; price : Nat; amount : Nat; expires_at : Nat64 }) : O.Order = {
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

  public func getExpiries(e : O.Expiries, t : Nat64) : ID.Many<()> = switch (RBTree.get(e, Nat64.compare, t)) {
    case (?found) found;
    case _ RBTree.empty();
  };

  public func saveExpiries(e : O.Expiries, t : Nat64, ids : ID.Many<()>) : O.Expiries = if (RBTree.size(ids) > 0) {
    RBTree.insert(e, Nat64.compare, t, ids);
  } else RBTree.delete(e, Nat64.compare, t);
};
