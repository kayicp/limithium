import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import V "Types";
import Nat "mo:base/Nat";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";

module {
  public func getBalance(s : V.Subaccount, token : Principal) : V.Balance = switch (RBTree.get(s, Principal.compare, token)) {
    case (?found) found;
    case _ ({ unlocked = 0; locked = 0 });
  };
  public func saveBalance(s : V.Subaccount, token : Principal, b : V.Balance) : V.Subaccount = if (b.unlocked > 0 or b.locked > 0) RBTree.insert(s, Principal.compare, token, b) else RBTree.delete(s, Principal.compare, token);

  public func getSubaccount(u : V.User, subacc : Blob) : V.Subaccount = switch (RBTree.get(u.subaccs, Blob.compare, subacc)) {
    case (?found) found;
    case _ RBTree.empty();
  };
  public func saveSubaccount(u : V.User, subacc_id : Blob, subacc : V.Subaccount) : V.User = ({
    u with subaccs = if (RBTree.size(subacc) > 0) RBTree.insert(u.subaccs, Blob.compare, subacc_id, subacc) else RBTree.delete(u.subaccs, Blob.compare, subacc_id);
  });
  public func getUser(users : V.Users, p : Principal) : V.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({
      last_activity = 0;
      subaccs = RBTree.empty();
    });
  };
  public func saveUser(users : V.Users, p : Principal, u : V.User) : V.Users = if (RBTree.size(u.subaccs) > 0) RBTree.insert(users, Principal.compare, p, u) else RBTree.delete(users, Principal.compare, p);

  public func incLock(b : V.Balance, amt : Nat) : V.Balance = {
    b with locked = b.locked + amt
  };
  public func decLock(b : V.Balance, amt : Nat) : V.Balance = {
    b with locked = b.locked - amt
  };
  public func incUnlock(b : V.Balance, amt : Nat) : V.Balance = {
    b with unlocked = b.unlocked + amt
  };
  public func decUnlock(b : V.Balance, amt : Nat) : V.Balance = {
    b with unlocked = b.unlocked - amt
  };
  public func dedupe(a : (Principal, V.TokenArg), b : (Principal, V.TokenArg)) : Order.Order = #equal; // todo: finish this, start with time;
};
