import B "Types";
import Book "Book";
import V "../vault_canister/Types";

import ICRC1T "../icrc1_canister/Types";
import ICRC1L "../icrc1_canister/ICRC1";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Buffer "mo:base/Buffer";
import Result "../util/motoko/Result";
import Time64 "../util/motoko/Time64";
import Subaccount "../util/motoko/Subaccount";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var meta : Value.Metadata = RBTree.empty();
  var users : B.Users = RBTree.empty();

  var order_id = 0;
  var orders = RBTree.empty<Nat, B.Order>();
  var orders_by_expiry : B.Expiries = RBTree.empty();

  var base = Book.newAmount(0); // sell unit
  var quote = Book.newAmount(0); // buy unit
  var sell_book : B.Book = RBTree.empty();
  var buy_book : B.Book = RBTree.empty();

  var trade_id = 0;
  var trades = RBTree.empty<Nat, B.Trade>();

  var place_dedupes : B.PlaceDedupes = RBTree.empty();

  var block_id = 0;
  var blocks = RBTree.empty<Nat, Value.Type>();

  // public shared query func book_base_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func book_quote_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func book_open(arg : B.PlaceArg) : async B.PlaceRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");
    let max_batch = Value.getNat(meta, B.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.orders.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.orders.size(); maximum_batch_size = max_batch });

    let env = switch (await* Book.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;

    var lsells = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lbase = 0;
    var lbuys = RBTree.empty<(price : Nat), { index : Nat; expiry : Nat64 }>();
    var lquote = 0;
    let instructions_buff = Buffer.Buffer<V.Instruction>(arg.orders.size());
    for (index in Iter.range(0, arg.orders.size() - 1)) {
      let o = arg.orders[index];
      let o_expiry = Option.get(o.expires_at, env.default_expires_at);
      if (o_expiry < env.min_expires_at) return #Err(#ExpiresTooSoon { index; minimum_expires_at = env.min_expires_at });
      if (o_expiry > env.max_expires_at) return #Err(#ExpiresTooLate { index; maximum_expires_at = env.max_expires_at });

      if (o.price < env.min_price) return #Err(#PriceTooLow { index; minimum_price = env.min_price });

      let nearest_price = Book.nearTick(o.price, env.price_tick);
      if (o.price != nearest_price) return #Err(#PriceTooFar { index; nearest_price });

      let min_amount = Nat.max(env.min_base_amount, env.min_quote_amount / o.price);
      if (o.amount < min_amount) return #Err(#AmountTooLow { index; minimum_amount = min_amount });

      let nearest_amount = Book.nearTick(o.amount, env.amount_tick);
      if (o.amount != nearest_amount) return #Err(#AmountTooFar { index; nearest_amount });

      let instruction = if (o.is_buy) {
        switch (RBTree.get(lbuys, Nat.compare, o.price)) {
          case (?found) return #Err(#DuplicatePrice { indexes = [found.index, index] });
          case _ ();
        };
        let lq = o.amount * o.price;
        lquote += lq;
        lbuys := RBTree.insert(lbuys, Nat.compare, o.price, { index; expiry = o_expiry });
        { token = env.quote_token_id; amount = lq };
      } else {
        switch (RBTree.get(lsells, Nat.compare, o.price)) {
          case (?found) return #Err(#DuplicatePrice { indexes = [found.index, index] });
          case _ ();
        };
        lbase += o.amount;
        lsells := RBTree.insert(lsells, Nat.compare, o.price, { index; expiry = o_expiry });
        { o with token = env.base_token_id };
      };
      instructions_buff.add({
        instruction with account = user_acct;
        action = #Lock;
      });
    };
    let min_lsell = RBTree.min(lsells);
    let max_lbuy = RBTree.max(lbuys);
    switch (min_lsell, max_lbuy) {
      case (?(lsell_price, lsell), ?(lbuy_price, lbuy)) if (lsell_price <= lbuy_price) return #Err(#PriceOverlap { sell_index = lsell.index; buy_index = lbuy.index });
      case _ (); // one of trees is empty : no overlap
    };
    var user = getUser(caller);
    let sub = Subaccount.get(arg.subaccount);
    var subacc = Book.getSubaccount(user, sub);

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
    // let fee_base = Value.getNat(meta, B.PLACE_FEE_BASE, 0) * RBTree.size(lsells);
    // let fee_quote = Value.getNat(meta, B.PLACE_FEE_QUOTE, 0) * RBTree.size(lbuys);
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
    // todo: check balance first ?
    let instructions = Buffer.toArray(instructions_buff);
    // todo: save user subaccount first
    let lock_ids = switch (await env.vault.vault_execute_granular(instructions)) {
      case (#Err err) return #Err(#ExecutionFailed { instructions; error = err });
      case (#Ok ok) ok;
    };
    base := Book.incAmount(base, Book.newAmount(lbase));
    quote := Book.incAmount(quote, Book.newAmount(lquote));
    var lorders = RBTree.empty<Nat, B.Order>(); // for blockify
    func newOrder(o : { index : Nat; expiry : Nat64 }) : B.Order {
      let new_order = Book.newOrder(lock_ids[o.index], env.now, { arg.orders[o.index] with owner = caller; subaccount = arg.subaccount; expires_at = o.expiry });
      orders := RBTree.insert(orders, Nat.compare, order_id, new_order);
      lorders := RBTree.insert(lorders, Nat.compare, order_id, new_order);

      var expiries = Book.getExpiries(orders_by_expiry, o.expiry);
      expiries := RBTree.insert(expiries, Nat.compare, order_id, ());
      orders_by_expiry := Book.saveExpiries(orders_by_expiry, o.expiry, expiries);
      new_order;
    };
    for ((o_price, o) in RBTree.entries(lsells)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(sell_book, o_price);
      price := Book.levelNewOrder(price, order_id, new_order);
      sell_book := Book.saveLevel(sell_book, o_price, price);
      subacc := Book.subaccNewSell(subacc, order_id, new_order);
      order_id += 1;
    };
    for ((o_price, o) in RBTree.entriesReverse(lbuys)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(buy_book, o_price);
      price := Book.levelNewOrder(price, order_id, new_order);
      buy_book := Book.saveLevel(buy_book, o_price, price);
      subacc := Book.subaccNewBuy(subacc, order_id, new_order);
      order_id += 1;
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    // todo: blockify
    // todo: save dedupe
    #Ok([]);
  };

  public shared ({ caller }) func book_close(arg : B.CancelArg) : async B.CancelRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");

    let max_batch = Value.getNat(meta, B.MAX_ORDER_BATCH, 0);
    if (max_batch > 0 and arg.orders.size() > max_batch) return #Err(#BatchTooLarge { batch_size = arg.orders.size(); maximum_batch_size = max_batch });

    let env = switch (await* Book.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;

    let fee_base = Value.getNat(meta, B.CANCEL_FEE_BASE, 0);
    let fee_quote = Value.getNat(meta, B.CANCEL_FEE_QUOTE, 0);
    // todo: dont check from user first, but check from orders right away only then check from user
    var user = getUser(caller);
    let sub = Subaccount.get(arg.subaccount);
    var subacc = Book.getSubaccount(user, sub);
    let now = Time64.nanos();
    var fbase = 0;
    var fquote = 0;
    let fee_collector = getFeeCollector();

    var lorders = RBTree.empty<Nat, { index : Nat; data : B.Order }>();
    // var lorders_by_expiry : B.Expiries = RBTree.empty();
    let instructions_buff = Buffer.Buffer<V.Instruction>(arg.orders.size() + 2);
    let instructions_indexes = Buffer.Buffer<?Nat>(arg.orders.size());
    for (index in Iter.range(0, arg.orders.size() - 1)) {
      let i = arg.orders[index];
      switch (RBTree.get(lorders, Nat.compare, i)) {
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
        let unfilled = o.base.initial - o.base.filled;
        o := Book.lockOrder(o, unfilled);
        let (amt, fee, tkn) = if (o.is_buy) (unfilled * o.price, fee_quote, env.quote_token_id) else (unfilled, fee_base, env.base_token_id);
        instructions_buff.add({
          account = user_acct;
          token = tkn;
          action = #Unlock;
          amount = amt;
        });
        if (o.expires_at < now) #Expired else if (amt > fee) #Canceled else #Filled;
      } else #Filled; // todo: no instruction, careful with the index
      if (reason == #Canceled) if (o.is_buy) fquote += fee_quote else fbase += fee_base;
      // o := { o with closed = ?{ at = now; reason } }; // todo: do this after execution successful
      lorders := RBTree.insert(lorders, Nat.compare, i, { index; data = o });
    };
    switch (arg.fee) {
      case (?defined) if (defined.base != fbase or defined.quote != fquote) return #Err(#BadFee { expected_base = fbase; expected_quote = fquote });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    // todo: check balance first before locking?
    var lbase = 0;
    var lquote = 0;
    for ((oid, o) in RBTree.entries(lorders)) {
      orders := RBTree.insert(orders, Nat.compare, oid, o.data);
      // var expiries = Book.getExpiries(lorders_by_expiry, o.expires_at);
      // if (RBTree.size(expiries) == 0) expiries := Book.getExpiries(orders_by_expiry, o.expires_at);
      // expiries := RBTree.delete(expiries, Nat.compare, i);
      // lorders_by_expiry := Book.saveExpiries(lorders_by_expiry, o.expires_at, expiries);

      // let o_ttl = o.expires_at + ttl;
      // expiries := Book.getExpiries(lorders_by_expiry, o_ttl);
      // if (RBTree.size(expiries) == 0) expiries := Book.getExpiries(orders_by_expiry, o_ttl);
      // expiries := RBTree.insert(expiries, Nat.compare, i, ());
      // lorders_by_expiry := Book.saveExpiries(lorders_by_expiry, o_ttl, expiries);
      if (o.data.is_buy) {
        var price = Book.getLevel(buy_book, o.data.price);
        price := Book.levelLock(price, o.data.base.locked);
        buy_book := Book.saveLevel(buy_book, o.data.price, price);

        let o_lock = o.data.base.locked * o.data.price;
        subacc := Book.subaccLockQuote(subacc, o_lock);
        quote := Book.lockAmount(quote, o_lock);
        lquote += o_lock;
      } else {
        var price = Book.getLevel(sell_book, o.data.price);
        price := Book.levelLock(price, o.data.base.locked);
        sell_book := Book.saveLevel(sell_book, o.data.price, price);

        subacc := Book.subaccLockBase(subacc, o.data.base.locked);
        base := Book.lockAmount(base, o.data.base.locked);
        lbase += o.data.base.locked;
      };
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);
    if (fbase > 0) instructions_buff.add({
      account = user_acct;
      token = env.base_token_id;
      amount = fbase;
      action = #Transfer { to = fee_collector };
    });
    if (fquote > 0) instructions_buff.add({
      account = user_acct;
      token = env.quote_token_id;
      amount = fquote;
      action = #Transfer { to = fee_collector };
    });
    let instructions = Buffer.toArray(instructions_buff);
    let unlock_id = switch (await env.vault.vault_execute_granular(instructions)) {
      case (#Err err) return #Err(#ExecutionFailed { instructions; error = err }); // todo: unlock/rollback
      case (#Ok ok) ok;
    };
    user := getUser(caller);
    subacc := Book.getSubaccount(user, sub);

    // todo: blockify

    #Ok 1;
  };

  func getUser(p : Principal) : B.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({ subaccs = RBTree.empty() });
  };
  func saveUser(p : Principal, u : B.User) : B.User {
    users := RBTree.insert(users, Principal.compare, p, u);
    u;
  };
  func checkMemo(m : ?Blob) : Result.Type<(), Error.Generic> = switch m {
    case (?defined) {
      var min_memo_size = Value.getNat(meta, B.MIN_MEMO, 1);
      if (min_memo_size < 1) {
        min_memo_size := 1;
        meta := Value.setNat(meta, B.MIN_MEMO, ?min_memo_size);
      };
      if (defined.size() < min_memo_size) return Error.text("Memo size must be larger than " # debug_show min_memo_size);

      var max_memo_size = Value.getNat(meta, B.MAX_MEMO, 1);
      if (max_memo_size < min_memo_size) {
        max_memo_size := min_memo_size;
        meta := Value.setNat(meta, B.MAX_MEMO, ?max_memo_size);
      };
      if (defined.size() > max_memo_size) return Error.text("Memo size must be smaller than " # debug_show max_memo_size);
      #Ok;
    };
    case _ #Ok;
  };
  func checkIdempotency(caller : Principal, opr : B.ArgType, now : Nat64, created_at_time : ?Nat64) : Result.Type<(), { #CreatedInFuture : { vault_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    var tx_window = Nat64.fromNat(Value.getNat(meta, B.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, B.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, B.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, B.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    switch (created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { vault_time = now });
        let (map, comparer, arg) = switch opr {
          case (#Place place) (place_dedupes, Book.dedupePlace, place);
        };
        switch (RBTree.get(map, comparer, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };

  var max_book = null : ?Nat;
  // var runners = RBTree.empty<Principal, Nat64>();
  public shared ({ caller }) func book_run(arg : B.RunArg) : async B.RunRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");
    // switch max_book {
    //   case (?found) switch (RBTree.maxKey(orders)) {
    //     case (?max_oid) if (max_oid == found) return await* run() else if (max_oid > found) {
    //       return #Err(#CorruptOrderBook { max_book; max_order = max_oid });
    //     };
    //     case _ return Error.text("Empty orderbook");
    //   };
    //   case _ {
    //     base := Book.newAmount(0); // reset orderbook
    //     quote := Book.newAmount(0);
    //     sell_book := RBTree.empty();
    //     buy_book := RBTree.empty();
    //   };
    // };

    Error.text("No job available");
  };

  func getFeeCollector() : ICRC1T.Account = {
    subaccount = null;
    owner = switch (Value.metaPrincipal(meta, B.FEE_COLLECTOR)) {
      case (?found) found;
      case _ Principal.fromActor(Self);
    };
  };

  func run() : async* B.RunRes {
    let env = switch (await* Book.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;
    var sell_p = switch (RBTree.min(sell_book)) {
      case (?(key, lvl)) ({ key; lvl });
      case _ return Error.text("Sell book is empty");
    };
    var buy_p = switch (RBTree.max(buy_book)) {
      case (?(key, lvl)) ({ key; lvl });
      case _ return Error.text("Buy book is empty");
    };
    let fee_collector = getFeeCollector();
    label matching while (true) {
      let move_sell = switch (await* match0(fee_collector, env, (sell_p.key, sell_p.lvl), (buy_p.key, buy_p.lvl))) {
        case (#Rest) break matching;
        case (#Ok ok) return #Ok ok;
        case (#Err err) return #Err err;
        case (#Next next_buy) next_buy;
      };
      if (move_sell) sell_p := switch (RBTree.right(sell_book, Nat.compare, sell_p.key + 1)) {
        case (?(key, lvl)) ({ key; lvl });
        case _ break matching;
      } else if (buy_p.key > 0) buy_p := switch (RBTree.left(buy_book, Nat.compare, buy_p.key - 1)) {
        case (?(key, lvl)) ({ key; lvl });
        case _ break matching;
      } else break matching;
    };
    // label trimming while true {

    // };
    // label archiving while true {

    // };
    Error.text("No job available");
  };

  func match0(fee_collector : ICRC1T.Account, env : B.Environment, (sell_p : Nat, _sell_lvl : B.Price), (buy_p : Nat, _buy_lvl : B.Price)) : async* {
    #Rest;
    #Ok : Nat;
    #Err : B.RunErr;
    #Next : Bool;
  } {
    var sell_lvl = _sell_lvl;
    var buy_lvl = _buy_lvl;
    var sell_id = switch (RBTree.minKey(sell_lvl.orders)) {
      case (?min) min;
      case _ {
        sell_book := RBTree.delete(sell_book, Nat.compare, sell_p);
        base := Book.decAmount(base, sell_lvl.base);
        return #Next false;
      };
    };
    var buy_id = switch (RBTree.minKey(buy_lvl.orders)) {
      case (?min) min;
      case _ {
        buy_book := RBTree.delete(buy_book, Nat.compare, buy_p);
        quote := Book.decAmount(quote, Book.mulAmount(buy_lvl.base, buy_p));
        return #Next true;
      };
    };
    label matching while true {
      let move_buy = switch (await* match1(fee_collector, env, (sell_id, sell_p, sell_lvl), (buy_id, buy_p, buy_lvl))) {
        case (#Rest) return #Rest;
        case (#Ok ok) return #Ok ok;
        case (#Err err) return #Err err;
        case (#SameId order) true;
        case (#SameOwner) true;
        case (#WrongPrice order) true;
        case (#WrongSide order) true;
        case (#Next is_buy) is_buy;
        case (#Closed is_buy) {
          is_buy;
        };
      };
      if (move_buy) buy_id := switch (RBTree.right(buy_lvl.orders, Nat.compare, buy_id + 1)) {
        case (?(found, _)) found;
        case _ return #Next true;
      } else sell_id := switch (RBTree.right(sell_lvl.orders, Nat.compare, sell_id + 1)) {
        case (?(found, _)) found;
        case _ return #Next true;
      };
    };
    #Rest;
  };

  func close(reason : { #Expired; #Filled }, oid : Nat, _o : B.Order, _lvl : B.Price, remain : Nat, env : B.Environment) : async* B.RunRes {
    var o = _o;
    var lvl = _lvl;
    var user = getUser(o.owner);
    let subacc_key = Subaccount.get(o.subaccount);
    var subacc = Book.getSubaccount(user, subacc_key);
    func execClose(proof : ?Nat) {
      o := { o with closed = ?{ at = env.now; reason; proof } };
      lvl := { lvl with orders = RBTree.delete(lvl.orders, Nat.compare, oid) };
      if (o.is_buy) {
        subacc := {
          subacc with buys = RBTree.delete(subacc.buys, Nat.compare, o.price)
        };
      } else {
        subacc := {
          subacc with sells = RBTree.delete(subacc.sells, Nat.compare, o.price)
        };
      };
    };
    func saveClose(expiry_too : Bool) {
      orders := RBTree.insert(orders, Nat.compare, oid, o);
      if (o.is_buy) buy_book := Book.saveLevel(buy_book, o.price, lvl) else sell_book := Book.saveLevel(sell_book, o.price, lvl);
      user := Book.saveSubaccount(user, subacc_key, subacc);
      user := saveUser(o.owner, user);
      if (expiry_too) {
        var expiries = Book.getExpiries(orders_by_expiry, o.expires_at);
        expiries := RBTree.delete(expiries, Nat.compare, oid);
        orders_by_expiry := Book.saveExpiries(orders_by_expiry, o.expires_at, expiries);

        let o_ttl = o.expires_at + env.ttl;
        expiries := Book.getExpiries(orders_by_expiry, o_ttl);
        expiries := RBTree.insert(expiries, Nat.compare, oid, ());
        orders_by_expiry := Book.saveExpiries(orders_by_expiry, o_ttl, expiries);
      };
    };
    if (remain == 0) {
      execClose(null);
      saveClose(true);
      // todo: blockify
      return #Ok 1;
    };
    o := { o with base = Book.lockAmount(o.base, remain) };
    lvl := Book.levelLock(lvl, remain);
    let (cid, amt) = if (o.is_buy) {
      let remain_q = remain * o.price;
      quote := Book.lockAmount(quote, remain_q);
      subacc := Book.subaccLockQuote(subacc, remain_q);
      (env.quote_token_id, remain_q);
    } else {
      base := Book.lockAmount(base, remain);
      subacc := Book.subaccLockBase(subacc, remain);
      (env.base_token_id, remain);
    };
    saveClose(false);

    func unlockClose() {
      user := getUser(o.owner);
      subacc := Book.getSubaccount(user, subacc_key);
      o := { o with base = Book.unlockAmount(o.base, remain) };
      if (o.is_buy) {
        lvl := Book.getLevel(buy_book, o.price);
        lvl := Book.levelUnlock(lvl, remain);
        quote := Book.unlockAmount(quote, amt);
        subacc := Book.subaccUnlockQuote(subacc, amt);
      } else {
        lvl := Book.getLevel(sell_book, o.price);
        lvl := Book.levelUnlock(lvl, remain);
        base := Book.unlockAmount(base, amt);
        subacc := Book.subaccUnlockBase(subacc, amt);
      };
    };
    let instruction = {
      account = o;
      token = cid;
      amount = amt;
      action = #Unlock;
    };
    try switch (await env.vault.vault_execute_aggregate([instruction])) {
      case (#Err err) {
        unlockClose();
        saveClose(false);
        #Err(#CloseFailed { order = oid; instructions = [instruction]; error = err });
      };
      case (#Ok ok) {
        unlockClose();
        execClose(?ok);
        saveClose(true);
        // todo: blockify
        #Ok 1;
      };
    } catch (err) {
      unlockClose();
      saveClose(false);
      #Err(Error.convert(err));
    };
  };

  func match1(fee_collector : ICRC1T.Account, env : B.Environment, (sell_id : Nat, sell_p : Nat, _sell_lvl : B.Price), (buy_id : Nat, buy_p : Nat, _buy_lvl : B.Price)) : async* {
    #Rest;
    #Ok : Nat; // worked
    #Err : B.RunErr;

    #WrongSide : B.Order;
    #WrongPrice : B.Order;
    #SameId : B.Order;
    #SameOwner;
    #Next : Bool;
    #Closed : Bool;
  } {
    if (sell_id == buy_id) {};
    var sell_o = switch (RBTree.get(orders, Nat.compare, sell_id)) {
      case (?found) found;
      case _ {
        return #Next false; // todo: return the level too?
      };
    };

    if (sell_o.is_buy) {
      return #Next false;
    };
    if (sell_o.price != sell_p) {

    };
    if (sell_o.closed != null) return #Closed false;
    if (sell_o.base.locked > 0) return #Next false;
    let sell_remain = if (sell_o.base.initial > sell_o.base.filled) sell_o.base.initial - sell_o.base.filled else 0;
    if (sell_o.expires_at < env.now) return await* close(#Expired, sell_id, sell_o, _sell_lvl, sell_remain, env);
    if (sell_remain < env.min_base_amount) return await* close(#Filled, sell_id, sell_o, _sell_lvl, sell_remain, env);

    var buy_o = switch (RBTree.get(orders, Nat.compare, buy_id)) {
      case (?found) found;
      case _ {
        return #Next true;
      };
    };

    if (not buy_o.is_buy) {
      return #Next true;
    };
    if (buy_o.price != buy_p) return #WrongPrice buy_o;
    if (buy_o.closed != null) return #Closed true;
    if (buy_o.base.locked > 0) return #Next true;
    let buy_remain = if (buy_o.base.initial > buy_o.base.filled) buy_o.base.initial - buy_o.base.filled else 0;
    if (buy_o.expires_at < env.now) return await* close(#Expired, buy_id, buy_o, _buy_lvl, buy_remain, env);
    if (buy_remain < env.min_base_amount) return await* close(#Filled, buy_id, buy_o, _buy_lvl, buy_remain, env);

    let sell_maker = sell_id < buy_id;
    let p = if (sell_maker) sell_o.price else buy_o.price;
    if (sell_remain * p < env.min_quote_amount) return await* close(#Filled, sell_id, sell_o, _sell_lvl, sell_remain, env);
    if (buy_remain * p < env.min_quote_amount) return await* close(#Filled, buy_id, buy_o, _buy_lvl, buy_remain, env);
    if (sell_o.price > buy_o.price) return #Rest;

    var seller = getUser(sell_o.owner);
    let sell_sub = Subaccount.get(sell_o.subaccount);
    var seller_sub = Book.getSubaccount(seller, sell_sub);
    var buyer = getUser(buy_o.owner);
    let buy_sub = Subaccount.get(buy_o.subaccount);
    var buyer_sub = Book.getSubaccount(buyer, buy_sub);
    if (sell_o.owner == buy_o.owner and sell_sub == buy_sub) return #SameOwner;

    let amount = Nat.min(sell_remain, buy_remain);
    let amount_q = amount * p;

    sell_o := { sell_o with base = Book.lockAmount(sell_o.base, amount) };
    buy_o := { buy_o with base = Book.lockAmount(buy_o.base, amount) };

    var sell_lvl = Book.levelLock(_sell_lvl, amount);
    var buy_lvl = Book.levelLock(_buy_lvl, amount);

    base := Book.lockAmount(base, amount);
    quote := Book.lockAmount(quote, amount_q);

    seller_sub := Book.subaccLockBase(seller_sub, amount);
    buyer_sub := Book.subaccLockQuote(buyer_sub, amount_q);

    func saveMatch() {
      orders := RBTree.insert(orders, Nat.compare, sell_id, sell_o);
      orders := RBTree.insert(orders, Nat.compare, buy_id, buy_o);
      sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);
      buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);
      seller := Book.saveSubaccount(seller, sell_sub, seller_sub);
      seller := saveUser(sell_o.owner, seller);
      buyer := Book.saveSubaccount(buyer, buy_sub, buyer_sub);
      buyer := saveUser(buy_o.owner, buyer);
    };
    saveMatch();

    let (seller_fee, buyer_fee) = if (sell_maker) (
      (env.maker_fee_numer * amount_q) / env.fee_denom,
      (env.taker_fee_numer * amount) / env.fee_denom,
    ) else (
      (env.taker_fee_numer * amount_q) / env.fee_denom,
      (env.maker_fee_numer * amount) / env.fee_denom,
    );
    let base_i = {
      account = sell_o;
      token = env.base_token_id;
      amount;
      action = #Unlock;
    };
    let quote_i = {
      account = buy_o;
      token = env.quote_token_id;
      amount = amount_q;
      action = #Unlock;
    };
    let instructions_buff = Buffer.Buffer<V.Instruction>(6);
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
    func unlockMatch() {
      sell_o := {
        sell_o with base = Book.unlockAmount(sell_o.base, amount)
      };
      buy_o := { buy_o with base = Book.unlockAmount(buy_o.base, amount) };
      base := Book.unlockAmount(base, amount);
      quote := Book.unlockAmount(quote, amount_q);

      sell_lvl := Book.getLevel(sell_book, sell_p);
      sell_lvl := Book.levelUnlock(sell_lvl, amount);
      buy_lvl := Book.getLevel(buy_book, buy_p);
      buy_lvl := Book.levelUnlock(buy_lvl, amount);

      seller := getUser(sell_o.owner);
      seller_sub := Book.getSubaccount(seller, sell_sub);
      seller_sub := Book.subaccUnlockBase(seller_sub, amount);
      buyer := getUser(buy_o.owner);
      buyer_sub := Book.getSubaccount(buyer, buy_sub);
      buyer_sub := Book.subaccUnlockQuote(buyer_sub, amount_q);
    };
    try switch (await env.vault.vault_execute_aggregate(instructions)) {
      case (#Err err) {
        unlockMatch();
        saveMatch();
        #Err(#TradeFailed { buy = buy_id; sell = sell_id; instructions; error = err });
      };
      case (#Ok ok) {
        unlockMatch();
        let sell = { id = sell_id; base = amount; fee_quote = seller_fee };
        let buy = { id = buy_id; quote = amount_q; fee_base = buyer_fee };
        let trade = { sell; buy; at = env.now; price = p; proof = ok };
        sell_o := Book.fillOrder(sell_o, amount, trade_id);
        buy_o := Book.fillOrder(buy_o, amount, trade_id);
        trades := RBTree.insert(trades, Nat.compare, trade_id, trade);
        trade_id += 1;

        base := Book.fillAmount(base, amount);
        quote := Book.fillAmount(quote, amount_q);
        sell_lvl := Book.levelFill(sell_lvl, amount);
        buy_lvl := Book.levelFill(buy_lvl, amount);
        seller_sub := Book.subaccFillBase(seller_sub, amount);
        buyer_sub := Book.subaccFillQuote(buyer_sub, amount_q);
        saveMatch();
        // todo: blockify
        #Ok 1;
      };
    } catch (err) {
      unlockMatch();
      saveMatch();
      #Err(Error.convert(err));
    };
  };

  func trim() {

  };

};
