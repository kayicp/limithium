import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import W "Types";
import Nat "mo:base/Nat";
import Order "mo:base/Order";
import ID "../util/motoko/ID";

module {
  public func getICRCBalance(s : W.Subaccount, token : Nat) : W.Balance = switch (ID.get(s.icrc2s, token)) {
    case (?found) found;
    case _ ({ unlocked = 0; locked = 0 });
  };
  public func saveICRCBalance(s : W.Subaccount, token : Nat, b : W.Balance) : W.Subaccount = ({
    s with icrc2s = ID.insert(s.icrc2s, token, b)
  });
  public func getSubaccount(u : W.User, subacc_id : Nat) : W.Subaccount = switch (ID.get(u.subaccs, subacc_id)) {
    case (?found) found;
    case _ ({ icrc2s = RBTree.empty() });
  };
  public func saveSubaccount(u : W.User, subacc_id : Nat, subacc : W.Subaccount) : W.User = ({
    u with subaccs = ID.insert(u.subaccs, subacc_id, subacc)
  });
  public func getBalance(asset_key : W.AssetKey, s : W.Subaccount) : W.Balance = switch asset_key {
    case (#ICRC1 token_id) getICRCBalance(s, token_id);
  };
  public func saveBalance(asset_key : W.AssetKey, s : W.Subaccount, b : W.Balance) : W.Subaccount = switch asset_key {
    case (#ICRC1 token_id) saveICRCBalance(s, token_id, b);
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
