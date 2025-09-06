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
};
