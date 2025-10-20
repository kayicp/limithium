import I "Types";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Management "../util/motoko/Management";
import Value "../util/motoko/Value";
import Result "../util/motoko/Result";
import Time64 "../util/motoko/Time64";
import Subaccount "../util/motoko/Subaccount";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Option "../util/motoko/Option";

module {
  public func validateAccount({ owner; subaccount } : I.Account) : Bool = if (Principal.isAnonymous(owner) or Principal.equal(owner, Management.principal()) or Principal.toBlob(owner).size() > 29) false else Subaccount.validate(subaccount);

  // todo: dont do this?
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

  public func dedupeTransfer((ap : Principal, a : I.TransferArg), (bp : Principal, b : I.TransferArg)) : Order.Order {
    switch (Option.compare(a.created_at_time, b.created_at_time, Nat64.compare)) {
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
    switch (Blob.compare(Subaccount.get(a.from_subaccount), Subaccount.get(b.from_subaccount))) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.fee, b.fee, Nat.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (compareAccount(a.to, b.to)) {
      case (#equal) Nat.compare(a.amount, b.amount);
      case other other;
    };
  };

  public func dedupeApprove((ap : Principal, a : I.ApproveArg), (bp : Principal, b : I.ApproveArg)) : Order.Order {
    switch (Option.compare(a.created_at_time, b.created_at_time, Nat64.compare)) {
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
    switch (Blob.compare(Subaccount.get(a.from_subaccount), Subaccount.get(b.from_subaccount))) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.expected_allowance, b.expected_allowance, Nat.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.expires_at, b.expires_at, Nat64.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.fee, b.fee, Nat.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (compareAccount(a.spender, b.spender)) {
      case (#equal) Nat.compare(a.amount, b.amount);
      case other other;
    };
  };

  public func dedupeTransferFrom((ap : Principal, a : I.TransferFromArg), (bp : Principal, b : I.TransferFromArg)) : Order.Order {
    switch (Option.compare(a.created_at_time, b.created_at_time, Nat64.compare)) {
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
    switch (Blob.compare(Subaccount.get(a.spender_subaccount), Subaccount.get(b.spender_subaccount))) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.fee, b.fee, Nat.compare)) {
      case (#equal) ();
      case other return other;
    };
    switch (compareAccount(a.from, b.from)) {
      case (#equal) ();
      case other return other;
    };
    switch (compareAccount(a.to, b.to)) {
      case (#equal) Nat.compare(a.amount, b.amount);
      case other other;
    };
  };

  // todo: provide sub for all subaccounts to save space
  public func valueTransfer(owner : Principal, a : I.TransferArg, mode : { #Burn; #Mint; #Transfer }, fee : Nat, now : Nat64, phash : ?Blob) : Value.Type {
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setNat(tx, "amt", ?a.amount);
    tx := Value.setBlob(tx, "memo", a.memo);
    switch (a.created_at_time) {
      case (?t) tx := Value.setNat(tx, "ts", ?Nat64.toNat(t));
      case _ ();
    };
    var map = RBTree.empty<Text, Value.Type>();
    switch (a.fee) {
      case (?found) if (found > 0) tx := Value.setNat(tx, "fee", ?found);
      case _ if (fee > 0) map := Value.setNat(map, "fee", ?fee);
    };
    switch mode {
      case (#Burn) {
        map := Value.setText(map, "op", ?"burn");
        tx := Value.setAccount(tx, "from", ?{ owner; subaccount = a.from_subaccount });
      };
      case (#Mint) {
        map := Value.setText(map, "op", ?"mint");
        tx := Value.setAccount(tx, "to", ?a.to);
      };
      case (#Transfer) {
        map := Value.setText(map, "op", ?"xfer");
        tx := Value.setAccount(tx, "from", ?{ owner; subaccount = a.from_subaccount });
        tx := Value.setAccount(tx, "to", ?a.to);
      };
    };
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };

  public func valueApprove(owner : Principal, a : I.ApproveArg, expires_at : Nat64, fee : Nat, now : Nat64, phash : ?Blob) : Value.Type {
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setNat(tx, "amt", ?a.amount);
    tx := Value.setBlob(tx, "memo", a.memo);
    tx := Value.setAccount(tx, "from", ?{ owner; subaccount = a.from_subaccount });
    tx := Value.setAccount(tx, "spender", ?a.spender);
    tx := Value.setNat(tx, "expected_allowance", a.expected_allowance);
    tx := Value.setNat(tx, "expires_at", ?Nat64.toNat(expires_at));
    switch (a.created_at_time) {
      case (?t) tx := Value.setNat(tx, "ts", ?Nat64.toNat(t));
      case _ ();
    };
    var map = RBTree.empty<Text, Value.Type>();
    switch (a.fee) {
      case (?found) if (found > 0) tx := Value.setNat(tx, "fee", ?found);
      case _ if (fee > 0) map := Value.setNat(map, "fee", ?fee);
    };
    map := Value.setText(map, "op", ?"approve");
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };

  public func valueTransferFrom(owner : Principal, a : I.TransferFromArg, fee : Nat, now : Nat64, phash : ?Blob) : Value.Type {
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setNat(tx, "amt", ?a.amount);
    tx := Value.setBlob(tx, "memo", a.memo);
    tx := Value.setAccount(tx, "spender", ?{ owner; subaccount = a.spender_subaccount });
    tx := Value.setAccount(tx, "from", ?a.from);
    tx := Value.setAccount(tx, "to", ?a.to);
    switch (a.created_at_time) {
      case (?t) tx := Value.setNat(tx, "ts", ?Nat64.toNat(t));
      case _ ();
    };
    var map = RBTree.empty<Text, Value.Type>();
    switch (a.fee) {
      case (?found) if (found > 0) tx := Value.setNat(tx, "fee", ?found);
      case _ if (fee > 0) map := Value.setNat(map, "fee", ?fee);
    };
    map := Value.setText(map, "op", ?"xfer");
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };

  public func getEnvironment(_meta : Value.Metadata) : Result.Type<I.Environment, Text> {
    var meta = _meta;
    let minter = switch (Value.metaAccount(meta, I.MINTER)) {
      case (?found) found;
      case _ return #Err("Metadata `" # I.MINTER # "` is not set properly.");
    };
    var fee = Value.getNat(meta, I.FEE, 0);
    // if (fee < 1) {
    //   fee := 1;
    //   meta := Value.setNat(meta, I.FEE, ?fee);
    // };
    let total_supply = Value.getNat(meta, I.TOTAL_SUPPLY, 0);
    // let min_supply = 1_000_000 * fee;
    // if (total_supply < min_supply) return #Err("Metadata `" # I.TOTAL_SUPPLY # "` must be at least " # debug_show min_supply);
    var max_mint = Value.getNat(meta, I.MAX_MINT, 0);
    // if (max_mint < fee) {
    //   max_mint := fee;
    //   meta := Value.setNat(meta, I.MAX_MINT, ?max_mint);
    // };
    let now = Time64.nanos();
    var tx_window = Nat64.fromNat(Value.getNat(meta, I.TX_WINDOW, 0));
    // let min_tx_window = Time64.MINUTES(15);
    // if (tx_window < min_tx_window) {
    //   tx_window := min_tx_window;
    //   meta := Value.setNat(meta, I.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    // };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, I.PERMITTED_DRIFT, 0));
    // let min_permitted_drift = Time64.SECONDS(5);
    // if (permitted_drift < min_permitted_drift) {
    //   permitted_drift := min_permitted_drift;
    //   meta := Value.setNat(meta, I.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    // };
    let dedupe_start = now - tx_window - permitted_drift;
    let dedupe_end = now + permitted_drift;
    #Ok {
      meta;
      minter;
      fee;
      now;
      max_mint;
      total_supply;
      dedupe_start;
      dedupe_end;
    };
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

  public func newExpiry(appr_exps : I.Expiries, t : Nat64, owner : Principal, o_sub : Blob, spender : Principal, s_sub : Blob) : I.Expiries {
    var ts = switch (RBTree.get(appr_exps, Nat64.compare, t)) {
      case (?found) found;
      case _ RBTree.empty();
    };
    var os = switch (RBTree.get(ts, Principal.compare, owner)) {
      case (?found) found;
      case _ RBTree.empty();
    };
    var oss = switch (RBTree.get(os, Blob.compare, o_sub)) {
      case (?found) found;
      case _ RBTree.empty();
    };
    var sps = switch (RBTree.get(oss, Principal.compare, spender)) {
      case (?found) found;
      case _ RBTree.empty();
    };
    sps := RBTree.insert(sps, Blob.compare, s_sub, ());
    oss := RBTree.insert(oss, Principal.compare, spender, sps);
    os := RBTree.insert(os, Blob.compare, o_sub, oss);
    ts := RBTree.insert(ts, Principal.compare, owner, os);
    RBTree.insert(appr_exps, Nat64.compare, t, ts);
  };
};
