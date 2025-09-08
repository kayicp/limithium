import O "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ID "../util/motoko/ID";
import Order "mo:base/Order";

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
};
