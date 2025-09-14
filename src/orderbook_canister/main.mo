import O "Types";
import OrderBook "OrderBook";
import Wallet "../wallet_canister/main";
import W "../wallet_canister/Types";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Account "../util/motoko/ICRC-1/Account";
import ID "../util/motoko/ID";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
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

  var order_id = 0;
  var orders = ID.empty<O.Order>();
  var orders_by_expiry : O.Expiries = RBTree.empty();

  var base = OrderBook.newAmount(0); // sell unit
  var quote = OrderBook.newAmount(0); // buy unit
  var sell_book : O.Book = RBTree.empty();
  var buy_book : O.Book = RBTree.empty();

  var place_dedupes : O.PlaceDedupes = RBTree.empty();

  // public shared query func orderbook_base_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func orderbook_quote_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func orderbook_open(arg : O.PlaceArg) : async O.PlaceRes {
    if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");
    let max_batch = Value.getNat(meta, O.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.orders.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.orders.size(); maximum_batch_size = max_batch });

    let env = switch (await* OrderBook.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;

    var lsells = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lbase = 0;
    var lbuys = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lquote = 0;
    for (index in Iter.range(0, arg.orders.size() - 1)) {
      let o = arg.orders[index];
      let o_expiry = Option.get(o.expires_at, env.default_expires_at);
      if (o_expiry < env.min_expires_at) return #Err(#ExpiresTooSoon { index; minimum_expires_at = env.min_expires_at });
      if (o_expiry > env.max_expires_at) return #Err(#ExpiresTooLate { index; maximum_expires_at = env.max_expires_at });

      if (o.price < env.min_price) return #Err(#PriceTooLow { index; minimum_price = env.min_price });

      let nearest_price = OrderBook.nearTick(o.price, env.price_tick);
      if (o.price != nearest_price) return #Err(#PriceTooFar { index; nearest_price });

      let min_amount = Nat.max(env.min_base_amount, env.min_quote_amount / o.price);
      if (o.amount < min_amount) return #Err(#AmountTooLow { index; minimum_amount = min_amount });

      let nearest_amount = OrderBook.nearTick(o.amount, env.amount_tick);
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
    var subacc = OrderBook.getSubaccount(user, arg_subacc);

    let min_gsell = RBTree.min(subacc.sells);
    let max_gbuy = RBTree.max(subacc.buys);
    switch (min_lsell, max_gbuy) {
      case (?(lsell_price, lsell), ?(gbuy_price, gbuy)) if (lsell_price <= gbuy_price) return #Err(#PriceTooLow { lsell with minimum_price = gbuy_price });
      case _ ();
    };
    switch (max_lbuy, min_gsell) {
      case (?(lbuy_price, lbuy), ?(gsell_price, gsell)) if (lbuy_price >= gsell_price) return #Err(#PriceTooHigh { lbuy with maximum_price = gsell_price });
      case _ ();
    };
    for ((lsell_price, lsell) in RBTree.entries(lsells)) switch (RBTree.get(subacc.sells, Nat.compare, lsell_price)) {
      case (?found) return #Err(#PriceUnavailable { lsell with order_id = found });
      case _ ();
    };
    for ((lbuy_price, lbuy) in RBTree.entries(lbuys)) switch (RBTree.get(subacc.buys, Nat.compare, lbuy_price)) {
      case (?found) return #Err(#PriceUnavailable { lbuy with order_id = found });
      case _ ();
    };
    // todo: skip since fee is zero anyway
    // let fee_base = Value.getNat(meta, O.PLACE_FEE_BASE, 0) * RBTree.size(lsells);
    // let fee_quote = Value.getNat(meta, O.PLACE_FEE_QUOTE, 0) * RBTree.size(lbuys);
    // switch (arg.fee) {
    //   case (?defined) if (defined.amount != null) if (defined.is_base) {
    //     if (defined.amount == ?fee_base) () else return #Err(#BadFee { expected_fee = fee_base });
    //   } else if (defined.amount == ?fee_quote) () else return #Err(#BadFee { expected_fee = fee_quote });
    //   case _ ();
    // };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #Place arg, env.now, arg.created_at_time)) {
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
      asset = #ICRC1 { canister_id = env.base_token_id };
      amount = lbase;
      action = #Lock;
    });
    if (lquote > 0) instructions_buff.add({
      account = user_acct;
      asset = #ICRC1 { canister_id = env.quote_token_id };
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
    func newOrder(o : { index : Nat; expiry : Nat64 }) : O.Order {
      let new_order = OrderBook.newOrder(env.now, { arg.orders[o.index] with owner = caller; subaccount = arg.subaccount; expires_at = o.expiry });
      orders := ID.insert(orders, order_id, new_order);
      lorders := ID.insert(lorders, order_id, new_order);

      var expiries = OrderBook.getExpiries(orders_by_expiry, o.expiry);
      expiries := ID.insert(expiries, order_id, ());
      orders_by_expiry := OrderBook.saveExpiries(orders_by_expiry, o.expiry, expiries);
      new_order;
    };
    for ((o_price, o) in RBTree.entries(lsells)) {
      let new_order = newOrder(o);
      var price = OrderBook.getPrice(sell_book, o_price);
      price := OrderBook.priceNewOrder(price, order_id, new_order);
      sell_book := OrderBook.savePrice(sell_book, o_price, price);
      subacc := OrderBook.subaccNewSell(subacc, order_id, new_order);
      order_id += 1;
    };
    for ((o_price, o) in RBTree.entries(lbuys)) {
      let new_order = newOrder(o);
      var price = OrderBook.getPrice(buy_book, o_price);
      price := OrderBook.priceNewOrder(price, order_id, new_order);
      buy_book := OrderBook.savePrice(buy_book, o_price, price);
      subacc := OrderBook.subaccNewBuy(subacc, order_id, new_order);
      order_id += 1;
    };
    user := OrderBook.saveSubaccount(user, arg_subacc, subacc);
    user := saveUser(caller, user);

    // todo: blockify
    // todo: save dedupe
    #Ok([]);
  };

  public shared ({ caller }) func orderbook_close(arg : O.CancelArg) : async O.CancelRes {
    if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    if (arg.order_ids.size() == 0) return Error.text("Orders must not be empty");

    let max_batch = Value.getNat(meta, O.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.order_ids.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.order_ids.size(); maximum_batch_size = max_batch });

    let min_ttl = Time64.DAYS(1);
    var ttl = Time64.SECONDS(Nat64.fromNat(Value.getNat(meta, O.TTL, 0)));
    if (ttl < min_ttl) {
      ttl := min_ttl;
      meta := Value.setNat(meta, O.TTL, ?86400);
    };
    let base_token_id = switch (Value.metaPrincipal(meta, O.BASE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.BASE_TOKEN # "` is not properly set");
    };
    let quote_token_id = switch (Value.metaPrincipal(meta, O.QUOTE_TOKEN)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # O.QUOTE_TOKEN # "` is not properly set");
    };
    let fee_base = Value.getNat(meta, O.PLACE_FEE_BASE, 0);
    let fee_quote = Value.getNat(meta, O.PLACE_FEE_QUOTE, 0);

    var user = getUser(caller);
    let arg_subacc = Account.denull(arg.subaccount);
    var subacc = OrderBook.getSubaccount(user, arg_subacc);
    let now = Time64.nanos();
    var fbase = 0;
    var fquote = 0;
    let self_acct = { owner = Principal.fromActor(Self); subaccount = null };

    var lorders = ID.empty<{ index : Nat; data : O.Order }>();
    // var lorders_by_expiry : O.Expiries = RBTree.empty();
    for (index in Iter.range(0, arg.order_ids.size() - 1)) {
      let i = arg.order_ids[index];
      switch (ID.get(lorders, i)) {
        case (?found) return #Err(#Duplicate { indexes = [found.index, index] });
        case _ ();
      };
      if (not RBTree.has(subacc.orders, Nat.compare, i)) return #Err(#Unauthorized { index });
      var o = switch (RBTree.get(orders, Nat.compare, i)) {
        case (?found) found;
        case _ return #Err(#NotFound { index });
      };
      switch (o.closed) {
        case (?yes) return #Err(#Closed { yes with index });
        case _ ();
      };
      if (o.base.locked > 0) return #Err(#Locked { index });
      let reason = if (o.base.initial > o.base.filled) {
        let o_base = { o.base with locked = o.base.initial - o.base.filled };
        o := { o with base = o_base };
        let (remaining, fee) = if (o.is_buy) (o.base.locked * o.price, fee_quote) else (o.base.locked, fee_base);
        if (o.expires_at < now) #Expired else if (remaining > fee) #Canceled else #Filled;
      } else #Filled;
      if (reason == #Canceled) if (o.is_buy) fquote += fee_quote else fbase += fee_base;
      o := { o with closed = ?{ at = now; reason } };
      lorders := ID.insert(lorders, i, { index; data = o });
    };
    switch (arg.fee) {
      case (?defined) if (defined.base != fbase or defined.quote != fquote) return #Err(#BadFee { expected_base = fbase; expected_quote = fquote });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let wallet = switch (Value.metaPrincipal(meta, O.WALLET)) {
      case (?found) actor (Principal.toText(found)) : Wallet.Canister;
      case _ return Error.text("Metadata `" # O.WALLET # "` not properly set");
    };
    // todo: check balance first before locking?
    var lbase = 0;
    var lquote = 0;
    for ((oid, o) in RBTree.entries(lorders)) {
      orders := ID.insert(orders, oid, o.data);
      // var expiries = OrderBook.getExpiries(lorders_by_expiry, o.expires_at);
      // if (RBTree.size(expiries) == 0) expiries := OrderBook.getExpiries(orders_by_expiry, o.expires_at);
      // expiries := RBTree.delete(expiries, Nat.compare, i);
      // lorders_by_expiry := OrderBook.saveExpiries(lorders_by_expiry, o.expires_at, expiries);

      // let o_ttl = o.expires_at + ttl;
      // expiries := OrderBook.getExpiries(lorders_by_expiry, o_ttl);
      // if (RBTree.size(expiries) == 0) expiries := OrderBook.getExpiries(orders_by_expiry, o_ttl);
      // expiries := RBTree.insert(expiries, Nat.compare, i, ());
      // lorders_by_expiry := OrderBook.saveExpiries(lorders_by_expiry, o_ttl, expiries);
      if (o.data.is_buy) {
        var price = OrderBook.getPrice(buy_book, o.data.price);
        price := OrderBook.priceLock(price, o.data.base.locked);
        buy_book := OrderBook.savePrice(buy_book, o.data.price, price);

        let o_lock = o.data.base.locked * o.data.price;
        subacc := OrderBook.subaccLockQuote(subacc, o_lock);
        quote := OrderBook.lockAmount(quote, o_lock);
        lquote += o_lock;
      } else {
        var price = OrderBook.getPrice(sell_book, o.data.price);
        price := OrderBook.priceLock(price, o.data.base.locked);
        sell_book := OrderBook.savePrice(sell_book, o.data.price, price);

        subacc := OrderBook.subaccLockBase(subacc, o.data.base.locked);
        base := OrderBook.lockAmount(base, o.data.base.locked);
        lbase += o.data.base.locked;
      };
    };
    user := OrderBook.saveSubaccount(user, arg_subacc, subacc);
    user := saveUser(caller, user);

    let instructions_buff = Buffer.Buffer<W.Instruction>(4);
    if (lbase > 0) {
      var instruction = {
        account = user_acct;
        asset = #ICRC1 { canister_id = base_token_id };
        amount = lbase;
        action = #Unlock;
      };
      instructions_buff.add(instruction);
      if (fbase > 0) instructions_buff.add({
        instruction with amount = fbase;
        action = #Transfer { to = self_acct };
      });
    };
    if (lquote > 0) {
      var instruction = {
        account = user_acct;
        asset = #ICRC1 { canister_id = quote_token_id };
        amount = lquote;
        action = #Unlock;
      };
      instructions_buff.add(instruction);
      if (fquote > 0) instructions_buff.add({
        instruction with amount = fquote;
        action = #Transfer { to = self_acct };
      });
    };
    let instructions = Buffer.toArray(instructions_buff);
    let unlock_id = switch (await wallet.wallet_execute(instructions)) {
      case (#Err err) return #Err(#ExecutionFailed { instructions; error = err }); // todo: unlock/rollback
      case (#Ok ok) ok;
    };
    user := getUser(caller);
    subacc := OrderBook.getSubaccount(user, arg_subacc);

    // let (base_token, quote_token) = (ICRC1Token.genActor(base_token_id), ICRC1Token.genActor(quote_token_id));

    #Ok 1;
  };

  func getUser(p : Principal) : O.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({ subaccs = RBTree.empty() });
  };
  func saveUser(p : Principal, u : O.User) : O.User {
    users := RBTree.insert(users, Principal.compare, p, u);
    u;
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

  public shared ({ caller }) func orderbook_run(arg : O.RunArg) : async O.RunRes {
    if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    label matching while (RBTree.size(sell_book) > 0 and RBTree.size(buy_book) > 0) for ((sell_p, sell_lvl) in RBTree.entries(sell_book)) for ((buy_p, buy_lvl) in RBTree.entriesReverse(buy_book))

    {
      let sell_id = switch (RBTree.minKey(sell_lvl.orders)) {
        case (?earliest) earliest;
        case _ {
          sell_book := RBTree.delete(sell_book, Nat.compare, sell_p);
          continue matching;
        };
      };
      var sell_o = switch (RBTree.get(orders, Nat.compare, sell_id)) {
        case (?found) found;
        case _ {
          let sell_os = RBTree.delete(sell_lvl.orders, Nat.compare, sell_id);
          sell_book := OrderBook.savePrice(sell_book, sell_p, { sell_lvl with orders = sell_os });
          continue matching;
        };
      };
      let buy_id = switch (RBTree.minKey(buy_lvl.orders)) {
        case (?earliest) earliest;
        case _ {
          buy_book := RBTree.delete(buy_book, Nat.compare, buy_p);
          continue matching;
        };
      };
      var buy_o = switch (RBTree.get(orders, Nat.compare, buy_id)) {
        case (?found) found;
        case _ {
          let buy_os = RBTree.delete(buy_lvl.orders, Nat.compare, buy_id);
          buy_book := OrderBook.savePrice(buy_book, buy_p, { buy_lvl with orders = buy_os });
          continue matching;
        };
      };

      // for ((sell_id, _) in RBTree.entries(sell_lvl.orders))
      // for ((buy_id));

    };

    // switch (RBTree.min(sell_book), RBTree.max(buy_book)) {
    //   case (?(min_sell_price, min_sell), ?(max_buy_price, max_buy)) if (min_sell_price <= max_buy_price) switch (RBTree.minKey(min_sell.orders), RBTree.minKey(max_buy.orders)) {
    //     case (?earliest_sell, ?earliest_buy) ignore match(min_sell_price, min_sell, earliest_sell, max_buy_price, max_buy, earliest_buy);
    //     case _ trim();
    //   } else trim();
    //   case _ trim();
    // };
    #Ok 1;
  };

  func getFeeCollector() : Account.Pair = {
    subaccount = null;
    owner = switch (Value.metaPrincipal(meta, O.FEE_COLLECTOR)) {
      case (?found) found;
      case _ Principal.fromActor(Self);
    };
  };

  func match0() : async* () {
    let wallet = switch (Value.metaPrincipal(meta, O.WALLET)) {
      case (?found) actor (Principal.toText(found)) : Wallet.Canister;
      case _ return; // Error.text("Metadata `" # O.WALLET # "` not properly set");
    };
    let env = switch (await* OrderBook.getEnvironment(meta)) {
      case (#Err err) return;
      case (#Ok ok) ok;
    };
    meta := env.meta;
    var sell_p = switch (RBTree.min(sell_book)) {
      case (?(key, lvl)) ({ key; lvl });
      case _ return;
    };
    var buy_p = switch (RBTree.max(buy_book)) {
      case (?(key, lvl)) ({ key; lvl });
      case _ return;
    };
    label matching while (true) {
      let move_sell = switch (await* match1(wallet, getFeeCollector(), env, (sell_p.key, sell_p.lvl), (buy_p.key, buy_p.lvl))) {
        case (#Return) return;
        case (#NextSell) true;
        case (#NextBuy) false;
      };
      if (move_sell) sell_p := switch (RBTree.right(sell_book, Nat.compare, sell_p.key + 1)) {
        case (?(key, lvl)) ({ key; lvl });
        case _ return;
      } else if (buy_p.key == 0) return else buy_p := switch (RBTree.left(buy_book, Nat.compare, buy_p.key - 1)) {
        case (?(key, lvl)) ({ key; lvl });
        case _ return;
      };
    };
  };

  func match1(wallet : Wallet.Canister, fee_collector : Account.Pair, env : O.Environment, (sell_p : Nat, _sell_lvl : O.Price), (buy_p : Nat, _buy_lvl : O.Price)) : async* {
    #Return;
    #NextSell;
    #NextBuy;
  } {
    var sell_lvl = _sell_lvl;
    var buy_lvl = _buy_lvl;
    var sell_id = switch (RBTree.minKey(sell_lvl.orders)) {
      case (?min) min;
      case _ {
        sell_book := RBTree.delete(sell_book, Nat.compare, sell_p);
        base := OrderBook.decAmount(base, sell_lvl.base);
        return #NextSell;
      };
    };
    var buy_id = switch (RBTree.minKey(buy_lvl.orders)) {
      case (?min) min;
      case _ {
        buy_book := RBTree.delete(buy_book, Nat.compare, buy_p);
        quote := OrderBook.decAmount(quote, OrderBook.mulAmount(buy_lvl.base, buy_p));
        return #NextBuy;
      };
    };
    label matching while true {
      let move_buy = switch (await* match2(wallet, fee_collector, env, (sell_id, sell_p, sell_lvl), (buy_id, buy_p, buy_lvl))) {
        case (#Return) return #Return;
        case (#SameId order) true;
        case (#SameOwner) true;
        case (#WrongPrice order) true;
        case (#WrongSide order) true;
        case (#Next is_buy) is_buy;
        case (#Missing is_buy) {
          if (is_buy) {
            let lvl_oids = RBTree.delete(buy_lvl.orders, Nat.compare, buy_id);
            buy_lvl := { buy_lvl with orders = lvl_oids };
            buy_book := OrderBook.savePrice(buy_book, buy_p, buy_lvl);
          } else {
            let lvl_oids = RBTree.delete(sell_lvl.orders, Nat.compare, sell_id);
            sell_lvl := { sell_lvl with orders = lvl_oids };
            sell_book := OrderBook.savePrice(sell_book, sell_p, sell_lvl);
          };
          is_buy;
        };
        case (#Closed is_buy) {
          is_buy;
        };
        case (#Close(is_buy, reason, order)) {
          is_buy;
        };
      };
      if (move_buy) buy_id := switch (RBTree.right(buy_lvl.orders, Nat.compare, buy_id + 1)) {
        case (?(found, _)) found;
        case _ return #NextBuy;
      } else sell_id := switch (RBTree.right(sell_lvl.orders, Nat.compare, sell_id + 1)) {
        case (?(found, _)) found;
        case _ return #NextSell;
      };
    };
    #Return;
  };

  func match2(wallet : Wallet.Canister, fee_collector : Account.Pair, env : O.Environment, (sell_id : Nat, sell_p : Nat, _sell_lvl : O.Price), (buy_id : Nat, buy_p : Nat, _buy_lvl : O.Price)) : async* {
    #Return;
    #Missing : Bool;
    #WrongSide : O.Order;
    #WrongPrice : O.Order;
    #SameId : O.Order;
    #SameOwner;
    #Next : Bool;
    #Closed : Bool;
    #Close : (Bool, { #Expired; #Filled }, O.Order);
  } {
    var sell_o = switch (RBTree.get(orders, Nat.compare, sell_id)) {
      case (?found) found;
      case _ return #Missing false;
    };
    if (sell_id == buy_id) return #SameId sell_o;

    if (sell_o.is_buy) return #WrongSide sell_o;
    if (sell_o.price != sell_p) return #WrongPrice sell_o;
    if (sell_o.closed != null) return #Closed false;
    if (sell_o.expires_at < env.now) return #Close(false, #Expired, sell_o);
    if (sell_o.base.locked > 0) return #Next false;
    let sell_remain = if (sell_o.base.initial > sell_o.base.filled) sell_o.base.initial - sell_o.base.filled else return #Close(false, #Filled, sell_o);
    if (sell_remain < env.min_base_amount) return #Close(false, #Filled, sell_o);

    var buy_o = switch (RBTree.get(orders, Nat.compare, buy_id)) {
      case (?found) found;
      case _ return #Missing true;
    };
    if (not buy_o.is_buy) return #WrongSide buy_o;
    if (buy_o.price != buy_p) return #WrongPrice buy_o;
    if (buy_o.closed != null) return #Closed true;
    if (buy_o.expires_at < env.now) return #Close(true, #Expired, buy_o);
    if (buy_o.base.locked > 0) return #Next true;
    let buy_remain = if (buy_o.base.initial > buy_o.base.filled) buy_o.base.initial - buy_o.base.filled else return #Close(true, #Filled, buy_o);
    if (buy_remain < env.min_base_amount) return #Close(true, #Filled, buy_o);

    let sell_maker = sell_id < buy_id;
    let p = if (sell_maker) sell_o.price else buy_o.price;
    if (sell_remain * p < env.min_quote_amount) return #Close(false, #Filled, sell_o);
    if (buy_remain * p < env.min_quote_amount) return #Close(true, #Filled, buy_o);
    if (sell_o.price > buy_o.price) return #Return;

    let sell_sub = Account.denull(sell_o.subaccount);
    let buy_sub = Account.denull(buy_o.subaccount);
    if (sell_o.owner == buy_o.owner and sell_sub == buy_sub) return #SameOwner;

    let amount = Nat.min(sell_remain, buy_remain);
    let amount_q = amount * p;

    // lock everything from here
    sell_o := { sell_o with base = OrderBook.lockAmount(sell_o.base, amount) };
    orders := RBTree.insert(orders, Nat.compare, sell_id, sell_o);
    buy_o := { buy_o with base = OrderBook.lockAmount(buy_o.base, amount) };
    orders := RBTree.insert(orders, Nat.compare, buy_id, buy_o);

    base := OrderBook.lockAmount(base, amount);
    quote := OrderBook.lockAmount(quote, amount_q);

    var sell_lvl = OrderBook.priceLock(_sell_lvl, amount);
    sell_book := OrderBook.savePrice(sell_book, sell_p, sell_lvl);
    var buy_lvl = OrderBook.priceLock(_buy_lvl, amount);
    buy_book := OrderBook.savePrice(buy_book, buy_p, buy_lvl);

    var seller = getUser(sell_o.owner);
    var seller_sub = OrderBook.getSubaccount(seller, sell_sub);
    seller_sub := OrderBook.subaccLockBase(seller_sub, amount);
    seller := OrderBook.saveSubaccount(seller, sell_sub, seller_sub);
    var buyer = getUser(buy_o.owner);
    var buyer_sub = OrderBook.getSubaccount(buyer, buy_sub);
    buyer_sub := OrderBook.subaccLockQuote(buyer_sub, amount_q);
    buyer := OrderBook.saveSubaccount(buyer, buy_sub, buyer_sub);

    let (seller_fee, buyer_fee) = if (sell_maker) (
      (env.maker_fee_numer * amount_q) / env.fee_denom,
      (env.taker_fee_numer * amount) / env.fee_denom,
    ) else (
      (env.taker_fee_numer * amount_q) / env.fee_denom,
      (env.maker_fee_numer * amount) / env.fee_denom,
    );
    let base_i = {
      account = sell_o;
      asset = #ICRC1 { canister_id = env.base_token_id };
      amount;
      action = #Unlock;
    };
    let quote_i = {
      account = buy_o;
      asset = #ICRC1 { canister_id = env.quote_token_id };
      amount;
      action = #Unlock;
    };
    let instructions_buff = Buffer.Buffer<W.Instruction>(6);
    instructions_buff.add(base_i);
    instructions_buff.add(quote_i);
    instructions_buff.add({ base_i with action = #Transfer { to = buy_o } });
    instructions_buff.add({ quote_i with action = #Transfer { to = sell_o } });
    if (seller_fee > 0) instructions_buff.add({
      quote_i with account = sell_o;
      amount = seller_fee;
      action = #Transfer { to = fee_collector };
    });
    if (buyer_fee > 0) instructions_buff.add({
      base_i with account = buy_o;
      amount = buyer_fee;
      action = #Transfer { to = fee_collector };
    });
    let instructions = Buffer.toArray(instructions_buff);
    switch (await wallet.wallet_execute(instructions)) {
      case (#Err err) {

      };
      case (#Ok ok) {

      };
    };
    #Return;
  };

  func trim() {

  };

};
