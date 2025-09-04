import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import W "Types";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";

module {
  public func recycleId<K>(ids : RBTree.Type<Nat, K>) : Nat = switch (RBTree.minKey(ids), RBTree.maxKey(ids)) {
    case (?min_id, ?max_id) if (min_id > 0) min_id - 1 else max_id + 1;
    case _ 0;
  };
  public func getICRCBalance(s : W.Subaccount, token : Nat) : W.Balance = switch (RBTree.get(s.icrc2s, Nat.compare, token)) {
    case (?found) found;
    case _ ({ unlocked = 0; locked = 0 });
  };
  public func saveICRCBalance(s : W.Subaccount, token : Nat, bal : W.Balance) : W.Subaccount = ({
    s with icrc2s = RBTree.insert(s.icrc2s, Nat.compare, token, bal)
  });
  public func getSubaccount(u : W.User, subacc_id : Nat) : W.Subaccount = switch (RBTree.get(u.subaccounts, Nat.compare, subacc_id)) {
    case (?found) found;
    case _ ({ icrc2s = RBTree.empty() });
  };
  public func saveSubaccount(u : W.User, subacc_id : Nat, subacc : W.Subaccount) : W.User = ({
    u with subaccounts = RBTree.insert(u.subaccounts, Nat.compare, subacc_id, subacc)
  });
  public func incLock(bal : W.Balance, amt : Nat) : W.Balance = {
    bal with locked = bal.locked + amt
  };
  public func decLock(bal : W.Balance, amt : Nat) : W.Balance = {
    bal with locked = bal.locked - amt
  };
  public func incUnlock(bal : W.Balance, amt : Nat) : W.Balance = {
    bal with unlocked = bal.unlocked + amt
  };
  public func decUnlock(bal : W.Balance, amt : Nat) : W.Balance = {
    bal with unlocked = bal.unlocked - amt
  };

};
