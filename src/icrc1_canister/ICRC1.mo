import I "Types";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Management "../util/motoko/Management";
import Value "../util/motoko/Value";
import Result "../util/motoko/Result";
import Time64 "../util/motoko/Time64";
import Subaccount "../util/motoko/Subaccount";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";

module {
  public func validateAccount({ owner; subaccount } : I.Account) : Bool = if (Principal.isAnonymous(owner) or Principal.equal(owner, Management.principal()) or Principal.toBlob(owner).size() > 29) false else Subaccount.validate(subaccount);

  public func compareAccount(a : I.Account, b : I.Account) : Order.Order = switch (Principal.compare(a.owner, b.owner)) {
    case (#equal) Blob.compare(Subaccount.get(a.subaccount), Subaccount.get(b.subaccount));
    case other other;
  };

  public func equalAccount(a : I.Account, b : I.Account) : Bool = compareAccount(a, b) == #equal;

  public func printAccount(a : I.Account) : Text = debug_show a;

  public func decBalance(s : I.Subaccount, n : Nat) : I.Subaccount = {
    s with balance = s.balance - n
  };
  public func incBalance(s : I.Subaccount, n : Nat) : I.Subaccount = {
    s with balance = s.balance + n
  };

  public func getSubaccount(u : I.Subaccounts, sub : Blob) : I.Subaccount = switch (RBTree.get(u, Blob.compare, sub)) {
    case (?found) found;
    case _ ({ balance = 0; spenders = RBTree.empty() });
  };

  public func saveSubaccount(u : I.Subaccounts, sub : Blob, s : I.Subaccount) : I.Subaccounts = if (s.balance > 0 or RBTree.size(s.spenders) > 0) RBTree.insert(u, Blob.compare, sub, s) else RBTree.delete(u, Blob.compare, sub);

  public func getSpender(sub : I.Subaccount, sp : Principal) : I.Approvals = switch (RBTree.get(sub.spenders, Principal.compare, sp)) {
    case (?found) found;
    case _ RBTree.empty();
  };

  public func saveSpender(s : I.Subaccount, sp : Principal, spender : I.Approvals) : I.Subaccount = {
    s with spenders = if (RBTree.size(spender) > 0) RBTree.insert(s.spenders, Principal.compare, sp, spender) else RBTree.delete(s.spenders, Principal.compare, sp);
  };

  public func getApproval(subs : I.Approvals, spsub : Blob) : I.Approval = switch (RBTree.get(subs, Blob.compare, spsub)) {
    case (?found) found;
    case _ ({ allowance = 0; expires_at = 0 });
  };

  public func decApproval(a : I.Approval, n : Nat) : I.Approval = {
    a with allowance = a.allowance - n
  };

  public func saveApproval(spender : I.Approvals, sub : Blob, amount : Nat, expires_at : Nat64) : I.Approvals = if (amount > 0) RBTree.insert(spender, Blob.compare, sub, { allowance = amount; expires_at }) else RBTree.delete(spender, Blob.compare, sub);

  public func dedupeTransfer((a_caller : Principal, a_arg : I.TransferArg), (b_caller : Principal, b_arg : I.TransferArg)) : Order.Order {
    #equal;
  };

  public func dedupeApprove((a_caller : Principal, a_arg : I.ApproveArg), (b_caller : Principal, b_arg : I.ApproveArg)) : Order.Order {
    #equal;
  };

  public func dedupeTransferFrom((a_caller : Principal, a_arg : I.TransferFromArg), (b_caller : Principal, b_arg : I.TransferFromArg)) : Order.Order {
    #equal;
  };

  public func getEnvironment(_meta : Value.Metadata) : Result.Type<I.Environment, Text> {
    var meta = _meta;
    let minter = switch (Value.metaAccount(meta, I.MINTER)) {
      case (?found) found;
      case _ return #Err("Metadata `" # I.MINTER # "` is not set properly.");
    };
    var fee = Value.getNat(meta, I.FEE, 0);
    if (fee < 1) {
      fee := 1;
      meta := Value.setNat(meta, I.FEE, ?1);
    };
    let now = Time64.nanos();
    #Ok { meta; minter; fee; now };
  };
  public func getExpiry(_meta : Value.Metadata, now : Nat64) : {
    max : Nat64;
    meta : Value.Metadata;
  } {
    var meta = _meta;
    var max_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, I.MAX_APPROVAL_EXPIRY, 0)));
    let highest_max_expiry = Time64.DAYS(30);
    if (max_expiry > highest_max_expiry) {
      max_expiry := highest_max_expiry;
      meta := Value.setNat(meta, I.MAX_APPROVAL_EXPIRY, ?(Nat64.toNat(highest_max_expiry / 1_000_000_000))); // save seconds
    };
    { meta; max = now + max_expiry };
  };
};
