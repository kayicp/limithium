import O "Types";
import OrderBook "OrderBook";
import Wallet "../wallet_canister/main";
import W "../wallet_canister/Types";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Account "../util/motoko/ICRC-1/Account";
import ICRC1Token "../util/motoko/ICRC-1/Types";
import ID "../util/motoko/ID";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Buffer "mo:base/Buffer";
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
  var orders = ID.empty<O.Order>();
  var orders_by_expiry : O.Expiries = RBTree.empty();

  var place_dedupes = RBTree.empty();

  // public shared query func orderbook_base_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func orderbook_quote_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func orderbook_place(arg : O.PlaceArg) : async O.PlaceRes {
    // if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");
    let max_batch = Value.getNat(meta, O.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.orders.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.orders.size(); maximum_batch_size = max_batch });

    let base_token_id = switch (Value.metaPrincipal(meta, O.BASE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.BASE_TOKEN # "` is not properly set");
    };
    let quote_token_id = switch (Value.metaPrincipal(meta, O.QUOTE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.QUOTE_TOKEN # "` is not properly set");
    };
    let (base_token, quote_token) = (ICRC1Token.genActor(base_token_id), ICRC1Token.genActor(quote_token_id));

    let (base_decimals_res, quote_decimals_res, base_fee_res, quote_fee_res) = (base_token.icrc1_decimals(), quote_token.icrc1_decimals(), base_token.icrc1_fee(), quote_token.icrc1_fee());
    let (base_power, quote_power, base_token_fee, quote_token_fee) = (10 ** Nat8.toNat(await base_decimals_res), 10 ** Nat8.toNat(await quote_decimals_res), await base_fee_res, await quote_fee_res);

    var amount_tick = Value.getNat(meta, O.AMOUNT_TICK, 0);
    if (amount_tick < base_token_fee) {
      amount_tick := base_token_fee;
      meta := Value.setNat(meta, O.AMOUNT_TICK, ?amount_tick);
    };
    var price_tick = Value.getNat(meta, O.PRICE_TICK, 0);
    if (price_tick < quote_token_fee) {
      price_tick := quote_token_fee;
      meta := Value.setNat(meta, O.PRICE_TICK, ?price_tick);
    };
    var fee_denom = Value.getNat(meta, O.TRADING_FEE_DENOM, 0);
    if (fee_denom < 100) {
      fee_denom := 100;
      meta := Value.setNat(meta, O.TRADING_FEE_DENOM, ?fee_denom);
    };
    var maker_fee_numer = Value.getNat(meta, O.MAKER_FEE_NUMER, 0);
    let max_fee_denom = fee_denom / 10; // max at most 10%
    if (maker_fee_numer > max_fee_denom) {
      maker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, O.MAKER_FEE_NUMER, ?maker_fee_numer);
    };
    var taker_fee_numer = Value.getNat(meta, O.TAKER_FEE_NUMER, 0);
    if (taker_fee_numer > max_fee_denom) {
      taker_fee_numer := max_fee_denom;
      meta := Value.setNat(meta, O.TAKER_FEE_NUMER, ?taker_fee_numer);
    };
    let min_fee_numer = Nat.max(1, Nat.min(maker_fee_numer, taker_fee_numer));
    // todo: rethink?
    // (tokenfee * 2) for amount + future transfer of amount
    let lowest_base_amount = base_token_fee * 2 * fee_denom / min_fee_numer;
    var min_base_amount = Value.getNat(meta, O.MIN_BASE_AMOUNT, 0);
    if (min_base_amount < lowest_base_amount) {
      min_base_amount := lowest_base_amount;
      meta := Value.setNat(meta, O.MIN_BASE_AMOUNT, ?min_base_amount);
    };
    let lowest_quote_amount = quote_token_fee * 2 * fee_denom / min_fee_numer;
    var min_quote_amount = Value.getNat(meta, O.MIN_QUOTE_AMOUNT, 0);
    if (min_quote_amount < lowest_quote_amount) {
      min_quote_amount := lowest_quote_amount;
      meta := Value.setNat(meta, O.MIN_QUOTE_AMOUNT, ?min_quote_amount);
    };
    let lowest_price = min_quote_amount / min_base_amount;
    var min_price = Value.getNat(meta, O.MIN_PRICE, 0);
    if (min_price < lowest_price) {
      min_price := lowest_price;
      meta := Value.setNat(meta, O.MIN_PRICE, ?min_price);
    };

    var max_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.MAX_ORDER_EXPIRY, 0)));
    let lowest_max_expiry = Time64.HOURS(24);
    let highest_max_expiry = lowest_max_expiry * 30;
    if (max_expiry < lowest_max_expiry) {
      max_expiry := lowest_max_expiry;
      meta := Value.setNat(meta, O.MAX_ORDER_EXPIRY, ?(Nat64.toNat(lowest_max_expiry / 1_000_000_000)));
    } else if (max_expiry > highest_max_expiry) {
      max_expiry := highest_max_expiry;
      meta := Value.setNat(meta, O.MAX_ORDER_EXPIRY, ?(Nat64.toNat(highest_max_expiry / 1_000_000_000)));
    };

    var min_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.MIN_ORDER_EXPIRY, 0)));
    let lowest_min_expiry = Time64.HOURS(1);
    let max_expiry_seconds = Nat64.toNat(max_expiry / 1_000_000_000);
    if (min_expiry < lowest_min_expiry) {
      min_expiry := lowest_min_expiry;
      meta := Value.setNat(meta, O.MIN_ORDER_EXPIRY, ?(Nat64.toNat(min_expiry / 1_000_000_000)));
    } else if (min_expiry > max_expiry) {
      min_expiry := max_expiry;
      meta := Value.setNat(meta, O.DEFAULT_ORDER_EXPIRY, ?max_expiry_seconds);
    };

    var default_expiry = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.DEFAULT_ORDER_EXPIRY, 0)));
    if (default_expiry < min_expiry or default_expiry > max_expiry) {
      default_expiry := (min_expiry + max_expiry) / 2;
      meta := Value.setNat(meta, O.DEFAULT_ORDER_EXPIRY, ?(Nat64.toNat(default_expiry / 1_000_000_000)));
    };

    let now = Time64.nanos();
    let max_expires_at = now + max_expiry;
    let min_expires_at = now + min_expiry;
    let default_expires_at = now + default_expiry;

    var lsells = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lbase = 0;
    var lbuys = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lquote = 0;
    for (index in Iter.range(0, arg.orders.size() - 1)) {
      let o = arg.orders[index];
      let o_expiry = Option.get(o.expires_at, default_expires_at);
      if (o_expiry < min_expires_at) return #Err(#ExpiresTooSoon { index; minimum_expires_at = min_expires_at });
      if (o_expiry > max_expires_at) return #Err(#ExpiresTooLate { index; maximum_expires_at = max_expires_at });

      if (o.price < min_price) return #Err(#PriceTooLow { index; minimum_price = min_price });

      let nearest_price = OrderBook.nearTick(o.price, price_tick);
      if (o.price != nearest_price) return #Err(#PriceTooFar { index; nearest_price });

      let min_amount = Nat.max(min_base_amount, min_quote_amount / o.price);
      if (o.amount < min_amount) return #Err(#AmountTooLow { index; minimum_amount = min_amount });

      let nearest_amount = OrderBook.nearTick(o.amount, amount_tick);
      if (o.amount != nearest_amount) return #Err(#AmountTooFar { index; nearest_amount });

      if (o.is_buy) {
        switch (RBTree.get(lbuys, Nat.compare, o.price)) {
          case (?found) return #Err(#DuplicatePrice { indexes = [found.index, index] });
          case _ ();
        };
        lquote += (o.amount * o.price);
        lbuys := RBTree.insert(lbuys, Nat.compare, o.price, { index; expiry = o_expiry });
      } else {
        switch (RBTree.get(lsells, Nat.compare, o.price)) {
          case (?found) return #Err(#DuplicatePrice { indexes = [found.index, index] });
          case _ ();
        };
        lbase += o.amount;
        lsells := RBTree.insert(lsells, Nat.compare, o.price, { index; expiry = o_expiry });
      };
    };

    let min_lsell = RBTree.min(lsells);
    let max_lbuy = RBTree.max(lbuys);
    switch (min_lsell, max_lbuy) {
      case (?(lsell_price, lsell), ?(lbuy_price, lbuy)) if (lsell_price <= lbuy_price) return #Err(#PriceOverlap { sell_index = lsell.index; buy_index = lbuy.index });
      case _ (); // one of trees is empty : no overlap
    };

    var user = getUser(caller);
    let arg_subacc = Account.denull(arg.subaccount);
    var subacc = getSubaccount(user, arg_subacc);

    let min_gsell = RBTree.min(subacc.data.sells);
    let max_gbuy = RBTree.max(subacc.data.buys);
    switch (min_lsell, max_gbuy) {
      case (?(lsell_price, lsell), ?(gbuy_price, gbuy)) if (lsell_price <= gbuy_price) return #Err(#PriceTooLow { lsell with minimum_price = gbuy_price });
      case _ ();
    };
    switch (max_lbuy, min_gsell) {
      case (?(lbuy_price, lbuy), ?(gsell_price, gsell)) if (lbuy_price >= gsell_price) return #Err(#PriceTooHigh { lbuy with maximum_price = gsell_price });
      case _ ();
    };
    for ((lsell_price, lsell) in RBTree.entries(lsells)) switch (RBTree.get(subacc.data.sells, Nat.compare, lsell_price)) {
      case (?found) return #Err(#PriceUnavailable { lsell with order_id = found });
      case _ ();
    };
    for ((lbuy_price, lbuy) in RBTree.entries(lbuys)) switch (RBTree.get(subacc.data.buys, Nat.compare, lbuy_price)) {
      case (?found) return #Err(#PriceUnavailable { lbuy with order_id = found });
      case _ ();
    };
    let fee_base = Value.getNat(meta, O.PLACE_FEE_BASE, 0);
    let fee_quote = Value.getNat(meta, O.PLACE_FEE_QUOTE, 0);
    switch (arg.fee) {
      case (?defined) if (defined.amount != null) if (defined.is_base) {
        if (defined.amount == ?fee_base) () else return #Err(#BadFee { expected_fee = fee_base });
      } else if (defined.amount == ?fee_quote) () else return #Err(#BadFee { expected_fee = fee_quote });
      case _ ();
    };
    // todo: check+take fee, but lets skip since no fee
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #Place arg, now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let wallet = switch (Value.metaPrincipal(meta, O.WALLET)) {
      case (?found) actor (Principal.toText(found)) : Wallet.Canister;
      case _ return Error.text("Metadata `" # O.WALLET # "` not properly set");
    };
    // todo: check balance first ? lock/reserve user too
    let instructions_buff = Buffer.Buffer<W.Instruction>(2);
    if (lbase > 0) instructions_buff.add({
      account = user_acct;
      asset = #ICRC1 { canister_id = base_token_id };
      amount = lbase;
      action = #Lock;
    });
    if (lquote > 0) instructions_buff.add({
      account = user_acct;
      asset = #ICRC1 { canister_id = quote_token_id };
      amount = lquote;
      action = #Lock;
    });
    let instructions = Buffer.toArray(instructions_buff);
    // todo: reserve user subaccount first
    let lock_id = switch (await wallet.wallet_execute(instructions)) {
      case (#Err err) return #Err(#ExecutionFailed { instructions; error = err });
      case (#Ok ok) ok;
    };
    base := OrderBook.incAmount(base, OrderBook.newAmount(lbase));
    quote := OrderBook.incAmount(quote, OrderBook.newAmount(lquote));
    var lorders = ID.empty<O.Order>(); // for blockify
    for ((o_price, o) in RBTree.entries(lsells)) {
      let new_order = OrderBook.newOrder(now, { arg.orders[o.index] with owner = user.id; subaccount = subacc.map.id; expires_at = o.expiry });
      orders := ID.insert(orders, order_id, new_order);
      lorders := ID.insert(lorders, order_id, new_order);
      // sell_book :=
      order_id += 1;
    };

    // todo: blockify
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
