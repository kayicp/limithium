import O "Types";
import OrderBook "OrderBook";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Account "../util/motoko/ICRC-1/Account";
import ID "../util/motoko/ID";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Result "../util/motoko/Result";
import Time64 "../util/motoko/Time64";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var meta : Value.Metadata = RBTree.empty();

  var users : O.Users = RBTree.empty();
  var user_ids = ID.empty<Principal>();
  var subacc_maps = RBTree.empty<Blob, O.SubaccountMap>();
  var subacc_ids = ID.empty<Blob>();

  var base = OrderBook.newAmount(0); // sell unit
  var quote = OrderBook.newAmount(0); // buy unit
  var sell_book : O.Book = RBTree.empty();
  var buy_book : O.Book = RBTree.empty();

  var order_id = 0;
  var orders = RBTree.empty<Nat, O.Order>();
  var orders_by_expiry : O.Expiries = RBTree.empty();

  var place_dedupes = RBTree.empty();

  // public shared query func orderbook_buy_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func orderbook_sell_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func orderbook_place(arg : O.PlaceArg) : async O.PlaceRes {
    // if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");
    let max_batch = Value.getNat(meta, O.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.orders.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.orders.size(); maximum_batch_size = max_batch });

    var user = getUser(caller);

    let lsells = RBTree.empty<(price : Nat), {}>();
    let lbuys = RBTree.empty<(price : Nat), {}>();
    for (o in arg.orders.vals()) {

    };
    #Ok([]);
  };

  public shared ({ caller }) func orderbook_cancel() : async () {

  };

  func getUser(p : Principal) : O.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({
      id = ID.recycle(user_ids);
      subaccs = RBTree.empty();
    });
  };
  func saveUser(p : Principal, u : O.User) : O.User {
    users := RBTree.insert(users, Principal.compare, p, u);
    user_ids := ID.insert(user_ids, u.id, p);
    u;
  };
  func getSubaccount(u : O.User, sub : Blob) : {
    map : O.SubaccountMap;
    data : O.Subaccount;
  } {
    let map = switch (RBTree.get(subacc_maps, Blob.compare, sub)) {
      case (?found) found;
      case _ ({
        id = ID.recycle(subacc_ids);
        owners = RBTree.empty();
      });
    };
    let owners = ID.insert(map.owners, u.id, ());
    { map = { map with owners }; data = OrderBook.getSubaccount(u, map.id) };
  };
  func saveSubaccount(u : O.User, sub : Blob, map : O.SubaccountMap, data : O.Subaccount) : O.User {
    subacc_maps := RBTree.insert(subacc_maps, Blob.compare, sub, map);
    subacc_ids := ID.insert(subacc_ids, map.id, sub);
    OrderBook.saveSubaccount(u, map.id, data);
  };
  func checkMemo(m : ?Blob) : Result.Type<(), Error.Generic> = switch m {
    case (?defined) {
      var min_memo_size = Value.getNat(meta, O.MIN_MEMO, 1);
      if (min_memo_size < 1) {
        min_memo_size := 1;
        meta := Value.setNat(meta, O.MIN_MEMO, ?min_memo_size);
      };
      if (defined.size() < min_memo_size) return Error.text("Memo size must be larger than " # debug_show min_memo_size);

      var max_memo_size = Value.getNat(meta, O.MAX_MEMO, 1);
      if (max_memo_size < min_memo_size) {
        max_memo_size := min_memo_size;
        meta := Value.setNat(meta, O.MAX_MEMO, ?max_memo_size);
      };
      if (defined.size() > max_memo_size) return Error.text("Memo size must be smaller than " # debug_show max_memo_size);
      #Ok;
    };
    case _ #Ok;
  };
  func checkIdempotency(caller : Principal, opr : O.ArgType, now : Nat64, created_at_time : ?Nat64) : Result.Type<(), { #CreatedInFuture : { ledger_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    var tx_window = Nat64.fromNat(Value.getNat(meta, O.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, O.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, O.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, O.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    switch (created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { ledger_time = now });
        let (map, comparer, arg) = switch opr {
          case (#Place place) (place_dedupes, OrderBook.dedupePlace, place);
        };
        switch (RBTree.get(map, comparer, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };

  public shared ({ caller }) func orderbook_run() : async () {

  };
};
