import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import V "Types";
import Nat "mo:base/Nat";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Value "../util/motoko/Value";
import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import Time64 "../util/motoko/Time64";
import Option "../util/motoko/Option";
import Subaccount "../util/motoko/Subaccount";

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
  public func valueBasic(op : Text, owner : Principal, sub : Blob, fee : Nat, arg : V.TokenArg, xfer : Nat, now : Nat64, phash : ?Blob) : Value.Type {
    let subaccount = if (sub.size() > 0) ?sub else null;
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setAccountP(tx, "acct", ?{ owner; subaccount });
    tx := Value.setPrincipal(tx, "token", ?arg.canister_id);
    tx := Value.setNat(tx, "amt", ?arg.amount);
    tx := Value.setBlob(tx, "memo", arg.memo);
    switch (arg.created_at) {
      case (?t) tx := Value.setNat(tx, "ts", ?Nat64.toNat(t));
      case _ ();
    };
    tx := Value.setNat(tx, "xfer", ?xfer);
    var map = RBTree.empty<Text, Value.Type>();
    switch (arg.fee) {
      case (?defined) if (defined > 0) tx := Value.setNat(tx, "fee", arg.fee);
      case _ if (fee > 0) map := Value.setNat(map, "fee", ?fee);
    };
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setText(map, "op", ?op);
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));
  };
  public func valueInstructions(caller : Principal, instructions : [Value.Type], now : Nat64, phash : ?Blob) : Value.Type {
    var tx = RBTree.empty<Text, Value.Type>();
    tx := Value.setPrincipal(tx, "xqtr", ?caller);
    tx := Value.setArray(tx, "cmds", instructions);
    var map = RBTree.empty<Text, Value.Type>();
    map := Value.setNat(map, "ts", ?Nat64.toNat(now));
    map := Value.setText(map, "op", ?"execute");
    map := Value.setMap(map, "tx", tx);
    map := Value.setBlob(map, "phash", phash);
    #Map(RBTree.array(map));

  };
  public func valueInstruction(i : V.Instruction) : Value.Type {
    var map = RBTree.empty<Text, Value.Type>();
    switch (i.action) {
      case (#Lock) {
        map := Value.setText(map, "op", ?"lock");
        map := Value.setAccountP(map, "acct", ?i.account);
      };
      case (#Unlock) {
        map := Value.setText(map, "op", ?"unlk");
        map := Value.setAccountP(map, "acct", ?i.account);
      };
      case (#Transfer { to }) {
        map := Value.setText(map, "op", ?"xfer");
        map := Value.setAccountP(map, "from", ?i.account);
        map := Value.setAccountP(map, "to", ?to);
      };
    };
    map := Value.setPrincipal(map, "token", ?i.token);
    map := Value.setNat(map, "amt", ?i.amount);
    #Map(RBTree.array(map));
  };

  public func dedupe((ap : Principal, a : V.TokenArg), (bp : Principal, b : V.TokenArg)) : Order.Order {
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
    switch (Principal.compare(a.canister_id, b.canister_id)) {
      case (#equal) ();
      case other return other;
    };
    switch (Option.compare(a.fee, b.fee, Nat.compare)) {
      case (#equal) ();
      case other return other;
    };
    Nat.compare(a.amount, b.amount);
  };

  public func getEnvironment(_meta : Value.Metadata) : Result.Type<V.Environment, Error.Generic> {
    var meta = _meta;
    let now = Time64.nanos();
    var tx_window = Nat64.fromNat(Value.getNat(meta, V.TX_WINDOW, 0));
    // let min_tx_window = Time64.MINUTES(15);
    // if (tx_window < min_tx_window) {
    //   tx_window := min_tx_window;
    //   meta := Value.setNat(meta, V.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    // };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, V.PERMITTED_DRIFT, 0));
    // let min_permitted_drift = Time64.SECONDS(5);
    // if (permitted_drift < min_permitted_drift) {
    //   permitted_drift := min_permitted_drift;
    //   meta := Value.setNat(meta, V.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    // };
    #Ok {
      meta;
      now;
      tx_window;
      permitted_drift;
    };
  };
};
