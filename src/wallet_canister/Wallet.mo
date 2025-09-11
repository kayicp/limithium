import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import W "Types";
import Nat "mo:base/Nat";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import ID "../util/motoko/ID";

module {
  public func getICRCBalance(s : W.Subaccount, token : Principal) : W.Balance = switch (RBTree.get(s.icrc1s, Principal.compare, token)) {
    case (?found) found;
    case _ ({ unlocked = 0; locked = 0 });
  };
  public func saveICRCBalance(s : W.Subaccount, token : Principal, b : W.Balance) : W.Subaccount = ({
    s with icrc1s = RBTree.insert(s.icrc1s, Principal.compare, token, b)
  });
  public func getSubaccount(u : W.User, subacc : Blob) : W.Subaccount = switch (RBTree.get(u.subaccs, Blob.compare, subacc)) {
    case (?found) found;
    case _ ({ icrc1s = RBTree.empty() });
  };
  public func saveSubaccount(u : W.User, subacc_id : Blob, subacc : W.Subaccount) : W.User = ({
    u with subaccs = RBTree.insert(u.subaccs, Blob.compare, subacc_id, subacc)
  });
  public func getBalance(asset : W.Asset, s : W.Subaccount) : W.Balance = switch asset {
    case (#ICRC1 token) getICRCBalance(s, token.canister_id);
  };
  public func saveBalance(asset : W.Asset, s : W.Subaccount, b : W.Balance) : W.Subaccount = switch asset {
    case (#ICRC1 token) saveICRCBalance(s, token.canister_id, b);
  };
  public func incLock(b : W.Balance, amt : Nat) : W.Balance = {
    b with locked = b.locked + amt
  };
  public func decLock(b : W.Balance, amt : Nat) : W.Balance = {
    b with locked = b.locked - amt
  };
  public func incUnlock(b : W.Balance, amt : Nat) : W.Balance = {
    b with unlocked = b.unlocked + amt
  };
  public func decUnlock(b : W.Balance, amt : Nat) : W.Balance = {
    b with unlocked = b.unlocked - amt
  };
  public func dedupeICRC(a : (Principal, W.ICRC1TokenArg), b : (Principal, W.ICRC1TokenArg)) : Order.Order = #equal; // todo: finish this, start with time;
};
