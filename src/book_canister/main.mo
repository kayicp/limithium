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
  var blocks = RBTree.empty<Nat, B.Block>();

  // public shared query func book_base_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func book_quote_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func book_open(arg : B.PlaceArg) : async B.PlaceRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    if (prev_build != RBTree.maxKey(orders)) return Error.text("Orderbook needs rebuilding. Please call `book_run`");

    let user_acc = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acc)) return Error.text("Caller account is not valid");

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
    let instructions_buff = Buffer.Buffer<[V.Instruction]>(arg.orders.size());
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
      instructions_buff.add([{
        instruction with account = user_acc;
        action = #Lock;
      }]);
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
    // todo: skip fee check since it's zero anyway
    let user_bals = await env.vault.vault_unlocked_balances_of([{ account = user_acc; token = env.base_token_id }, { account = user_acc; token = env.quote_token_id }]);
    if (user_bals[0] < lbase or user_bals[1] < lquote) return #Err(#InsufficientBalance { base_balance = user_bals[0]; quote_balance = user_bals[1] });
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #Place arg, env.now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let instruction_blocks = Buffer.toArray(instructions_buff);
    let exec_ids = switch (await env.vault.vault_execute(instruction_blocks)) {
      case (#Err err) return #Err(#ExecutionFailed { instruction_blocks; error = err });
      case (#Ok ok) ok;
    };
    user := getUser(caller);
    subacc := Book.getSubaccount(user, sub);
    base := Book.incAmount(base, Book.newAmount(lbase));
    quote := Book.incAmount(quote, Book.newAmount(lquote));
    func newOrder(o : { index : Nat; expiry : Nat64 }) : B.Order {
      let new_order = Book.newOrder(exec_ids[o.index], block_id, env.now, { arg.orders[o.index] with owner = caller; sub; expires_at = o.expiry });
      orders := RBTree.insert(orders, Nat.compare, order_id, new_order);
      subacc := Book.subaccNewOrder(subacc, order_id);

      orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expiry, order_id);
      new_order;
    };
    for ((o_price, o) in RBTree.entries(lsells)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(sell_book, o_price);
      price := Book.levelNewOrder(price, order_id);
      price := Book.levelIncAmount(price, new_order.base);
      sell_book := Book.saveLevel(sell_book, o_price, price);
      subacc := Book.subaccNewSell(subacc, order_id, new_order);
      subacc := Book.subaccIncBase(subacc, new_order.base);
      order_id += 1;
    };
    for ((o_price, o) in RBTree.entriesReverse(lbuys)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(buy_book, o_price);
      price := Book.levelNewOrder(price, order_id);
      price := Book.levelIncAmount(price, new_order.base);
      buy_book := Book.saveLevel(buy_book, o_price, price);
      subacc := Book.subaccNewBuy(subacc, order_id, new_order);
      subacc := Book.subaccIncQuote(subacc, Book.mulAmount(new_order.base, new_order.price));
      order_id += 1;
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    // todo: blockify
    // todo: save dedupe
    #Ok([]);
  };

  // todo: only blockify refundable orders, close the rest in background (if it's in the arg, dont return error but relax)
  public shared ({ caller }) func book_close(arg : B.CancelArg) : async B.CancelRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    if (prev_build != RBTree.maxKey(orders)) return Error.text("Orderbook needs rebuilding. Please call `book_run`");

    let user_acc = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acc)) return Error.text("Caller account is not valid");

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

    let sub = Subaccount.get(arg.subaccount);
    let fee_collector = getFeeCollector();

    var lbase = 0;
    var lquote = 0;
    var fulls = RBTree.empty<Nat, { index : Nat; data : B.Order }>();
    var refundables = RBTree.empty<Nat, { index : Nat; data : B.Order; reason : { #AlmostFilled : Null; #Expired : Null; #Canceled : Null }; instruction_index : Nat }>();
    let refunds_buff = Buffer.Buffer<[V.Instruction]>(arg.orders.size());
    var total_fee_base = 0;
    var total_fee_quote = 0;
    let last_index = arg.orders.size() - 1;
    for (index in Iter.range(0, last_index)) {
      let oid = arg.orders[index];
      switch (RBTree.get(refundables, Nat.compare, oid)) {
        case (?found) return #Err(#Duplicate { indexes = [found.index, index] });
        case _ ();
      };
      switch (RBTree.get(fulls, Nat.compare, oid)) {
        case (?found) return #Err(#Duplicate { indexes = [found.index, index] });
        case _ ();
      };
      var o = switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) found;
        case _ return #Err(#NotFound { index });
      };
      if (o.owner != caller or o.sub != sub) return #Err(#Unauthorized { index });
      switch (o.closed) {
        case (?yes) return #Err(#Closed { yes with index });
        case _ ();
      };
      if (o.base.locked > 0) return #Err(#Locked { index });
      if (o.base.initial > o.base.filled) {
        let unfilled = o.base.initial - o.base.filled;
        o := Book.lockOrder(o, unfilled);
        let (reason, instructions) = if (o.is_buy) {
          let o_quote = unfilled * o.price;
          lquote += o_quote;
          let instruction = {
            account = user_acc;
            token = env.quote_token_id;
            amount = o_quote;
            action = #Unlock;
          };
          if (o.expires_at < env.now) (#Expired null, [instruction]) else if (o_quote < env.min_quote_amount) (#AlmostFilled null, [instruction]) else {
            total_fee_quote += fee_quote;
            (#Canceled null, [instruction, { instruction with amount = fee_quote; action = #Transfer { to = fee_collector } }]);
          };
        } else {
          lbase += unfilled;
          let instruction = {
            account = user_acc;
            token = env.base_token_id;
            amount = unfilled;
            action = #Unlock;
          };
          if (o.expires_at < env.now) (#Expired null, [instruction]) else if (unfilled < env.min_base_amount) (#AlmostFilled null, [instruction]) else {
            total_fee_base += fee_base;
            (#Canceled null, [instruction, { instruction with amount = fee_base; action = #Transfer { to = fee_collector } }]);
          };
        };
        let instruction_index = refunds_buff.size();
        refunds_buff.add(instructions);
        o := { o with closed = ?{ caller; sub; reason; at = env.now } };
        refundables := RBTree.insert(refundables, Nat.compare, oid, { index; data = o; reason; instruction_index });
      } else {
        let closed = ?{ caller; sub; reason = #FullyFilled; at = env.now };
        o := { o with closed };
        fulls := RBTree.insert(fulls, Nat.compare, oid, { index; data = o });
      };
    };
    switch (arg.fee) {
      case (?defined) if (defined.base != total_fee_base or defined.quote != total_fee_quote) return #Err(#BadFee { expected_base = total_fee_base; expected_quote = total_fee_quote });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    var user = getUser(caller); // save the locked orders to prevent double cancels
    var subacc = Book.getSubaccount(user, sub);
    if (RBTree.size(fulls) > 0) {
      for ((oid, o) in RBTree.entries(fulls)) {
        orders := RBTree.insert(orders, Nat.compare, oid, o.data);
        subacc := if (o.data.is_buy) {
          var pr = Book.getLevel(buy_book, o.data.price);
          pr := Book.levelDecAmount(pr, o.data.base);
          pr := Book.levelDelOrder(pr, oid);
          buy_book := Book.saveLevel(buy_book, o.data.price, pr);

          let o_quote = Book.mulAmount(o.data.base, o.data.price);
          quote := Book.decAmount(quote, o_quote);
          Book.subaccDecQuote(subacc, o_quote);
        } else {
          var pr = Book.getLevel(sell_book, o.data.price);
          pr := Book.levelDecAmount(pr, o.data.base);
          pr := Book.levelDelOrder(pr, oid);
          sell_book := Book.saveLevel(sell_book, o.data.price, pr);

          base := Book.decAmount(base, o.data.base);
          Book.subaccDecBase(subacc, o.data.base);
        };
        orders_by_expiry := Book.delExpiry(orders_by_expiry, o.data.expires_at, oid);
        orders_by_expiry := Book.newExpiry(orders_by_expiry, o.data.expires_at + env.ttl, oid);
      };
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(caller, user);
    };
    if (RBTree.size(refundables) == 0) return #Err(#Closed { index = 0; at = env.now });

    let user_bals = await env.vault.vault_locked_balances_of([{ account = user_acc; token = env.base_token_id }, { account = user_acc; token = env.quote_token_id }]);
    if (user_bals[0] < lbase or user_bals[1] < lquote) return #Err(#InsufficientBalance { base_balance = user_bals[0]; quote_balance = user_bals[1] }); // todo: save lock before await?

    base := Book.lockAmount(base, lbase);
    quote := Book.lockAmount(quote, lquote);

    for ((oid, o) in RBTree.entries(refundables)) {
      orders := RBTree.insert(orders, Nat.compare, oid, o.data);
      if (o.data.is_buy) {
        var price = Book.getLevel(buy_book, o.data.price);
        price := Book.levelLock(price, o.data.base.locked);
        buy_book := Book.saveLevel(buy_book, o.data.price, price);
      } else {
        var price = Book.getLevel(sell_book, o.data.price);
        price := Book.levelLock(price, o.data.base.locked);
        sell_book := Book.saveLevel(sell_book, o.data.price, price);
      };
    };
    subacc := Book.subaccLockQuote(subacc, lquote);
    subacc := Book.subaccLockBase(subacc, lbase);
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);
    let instruction_blocks = Buffer.toArray(refunds_buff);
    let execute_res = await env.vault.vault_execute(instruction_blocks);
    func unlock(execute_ok : ?[Nat]) {
      user := getUser(caller);
      subacc := Book.getSubaccount(user, sub);
      for ((oid, o) in RBTree.entries(refundables)) {
        var order = o.data;
        var price = if (order.is_buy) {
          var pr = Book.getLevel(buy_book, order.price);
          pr := Book.levelUnlock(pr, order.base.locked);
          buy_book := Book.saveLevel(buy_book, order.price, pr);
          var o_quote = order.base.locked * order.price;
          quote := Book.unlockAmount(quote, o_quote);
          subacc := Book.subaccUnlockQuote(subacc, o_quote);
          pr;
        } else {
          var pr = Book.getLevel(sell_book, order.price);
          pr := Book.levelUnlock(pr, order.base.locked);
          sell_book := Book.saveLevel(sell_book, order.price, pr);
          base := Book.unlockAmount(base, order.base.locked);
          subacc := Book.subaccUnlockBase(subacc, order.base.locked);
          pr;
        };
        order := Book.unlockOrder(order, order.base.locked);
        let closed = switch execute_ok {
          case (?exec_ids) {
            price := Book.levelDelOrder(price, oid);
            price := Book.levelDecAmount(price, order.base);
            if (order.is_buy) {
              buy_book := Book.saveLevel(buy_book, order.price, price);
              let o_quote = Book.mulAmount(order.base, order.price);
              quote := Book.decAmount(quote, o_quote);
              subacc := Book.subaccDecQuote(subacc, o_quote);
            } else {
              sell_book := Book.saveLevel(sell_book, order.price, price);
              base := Book.decAmount(base, order.base);
              subacc := Book.subaccDecBase(subacc, order.base);
            };
            orders_by_expiry := Book.delExpiry(orders_by_expiry, order.expires_at, oid);
            orders_by_expiry := Book.newExpiry(orders_by_expiry, order.expires_at + env.ttl, oid);

            let execute = exec_ids[o.instruction_index];
            let proof = ?{ block = block_id; execute };
            let reason = switch (o.reason) {
              case (#AlmostFilled _) #AlmostFilled proof;
              case (#Canceled _) #Canceled proof;
              case (#Expired _) #Expired proof;
            };
            ?{ caller; sub; at = env.now; reason };
          };
          case _ null;
        };
        order := { order with closed };
        orders := RBTree.insert(orders, Nat.compare, oid, order);
      };
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(caller, user);
    };
    let execution_ids = switch execute_res {
      case (#Err err) {
        unlock(null);
        return #Err(#ExecutionFailed { instruction_blocks; error = err });
      };
      case (#Ok ok) ok;
    };
    unlock(?execution_ids);
    // todo: blockify
    #Ok 1;
  };

  public shared query func archive_min_block() : async ?Nat = async RBTree.minKey(blocks);

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

  var prev_build = null : ?Nat;
  public shared ({ caller }) func book_run(arg : B.RunArg) : async B.RunRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acc = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acc)) return Error.text("Caller account is not valid");
    let sub = Subaccount.get(arg.subaccount);
    switch prev_build {
      case (?built_until) switch (RBTree.maxKey(orders)) {
        case (?max_oid) switch (Nat.compare(built_until, max_oid)) {
          case (#less) build();
          case _ await* run(caller, sub);
        };
        case _ Error.text("Empty orders");
      };
      case _ {
        users := RBTree.empty(); // rebuild everything using orders
        orders_by_expiry := RBTree.empty();
        base := Book.newAmount(0);
        quote := Book.newAmount(0);
        sell_book := RBTree.empty();
        buy_book := RBTree.empty();
        build();
      };
    };
  };

  func getFeeCollector() : ICRC1T.Account = {
    subaccount = null;
    owner = switch (Value.metaPrincipal(meta, B.FEE_COLLECTOR)) {
      case (?found) found;
      case _ Principal.fromActor(Self);
    };
  };

  // todo: if build mode is on, pause open/close/run order
  func build() : B.RunRes {
    let res = Buffer.Buffer<Nat>(100);
    label building for (i in Iter.range(0, 100 - 1)) {
      let get_order = switch prev_build {
        case (?prev) RBTree.right(orders, Nat.compare, prev + 1);
        case _ RBTree.min(orders);
      };
      let (oid, o) = switch get_order {
        case (?found) found;
        case _ if (RBTree.size(orders) > 0) break building else return Error.text("No build required: empty orderbook");
      };
      let is_open = switch (o.closed) {
        case (?cl) if (Book.isClosing(cl.reason)) return Error.text("Try again later: Order " # debug_show oid # " is still closing. Built: " # debug_show (Buffer.toArray(res))) else false;
        case _ true;
      };
      var user = getUser(o.owner);
      var subacc = Book.getSubaccount(user, o.sub);
      subacc := Book.subaccNewOrder(subacc, oid);
      if (is_open) {
        if (o.is_buy) {
          var pr = Book.getLevel(buy_book, o.price);
          pr := Book.levelNewOrder(pr, oid);
          pr := Book.levelIncAmount(pr, o.base);
          buy_book := Book.saveLevel(buy_book, o.price, pr);
          subacc := Book.subaccNewBuy(subacc, oid, o);
          let o_quote = Book.mulAmount(o.base, o.price);
          subacc := Book.subaccIncQuote(subacc, o_quote);
          quote := Book.incAmount(quote, o_quote);
        } else {
          var pr = Book.getLevel(sell_book, o.price);
          pr := Book.levelNewOrder(pr, oid);
          pr := Book.levelIncAmount(pr, o.base);
          sell_book := Book.saveLevel(sell_book, o.price, pr);
          subacc := Book.subaccNewSell(subacc, oid, o);
          subacc := Book.subaccIncBase(subacc, o.base);
          base := Book.incAmount(base, o.base);
        };
      };
      user := Book.saveSubaccount(user, o.sub, subacc);
      user := saveUser(o.owner, user);

      prev_build := ?oid;
      res.add(oid);
    };
    Error.text("Built: " # debug_show (Buffer.toArray(res)));
  };

  func rebuild(msg : Text) : Error.Result {
    prev_build := null;
    Error.text("Rebuilding: " # msg);
  };
  func run(caller : Principal, sub : Blob) : async* B.RunRes {
    let env = switch (await* Book.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;
    let fee_collector = getFeeCollector();
    var start_sell_lvl = true;
    var start_buy_lvl = true;
    var next_sell_lvl = false;
    var next_buy_lvl = false;
    var sell_p = 0;
    var buy_p = 0;
    var sell_lvl = Book.getLevel(RBTree.empty(), 0);
    var buy_lvl = Book.getLevel(RBTree.empty(), 0);
    label pricing while true {
      if (start_sell_lvl) switch (RBTree.min(sell_book)) {
        case (?(p, lvl)) {
          sell_p := p;
          sell_lvl := lvl;
          start_sell_lvl := false;
        };
        case _ return await* trim(caller, sub, env);
      } else if (next_sell_lvl) switch (RBTree.right(sell_book, Nat.compare, sell_p + 1)) {
        case (?(p, lvl)) {
          sell_p := p;
          sell_lvl := lvl;
          next_sell_lvl := false;
        };
        case _ return await* trim(caller, sub, env);
      } else ();

      if (start_buy_lvl) switch (RBTree.max(buy_book)) {
        case (?(p, lvl)) {
          buy_p := p;
          buy_lvl := lvl;
          start_buy_lvl := false;
        };
        case _ return await* trim(caller, sub, env);
      } else if (next_buy_lvl) {
        if (buy_p > 0) switch (RBTree.left(buy_book, Nat.compare, buy_p - 1)) {
          case (?(p, lvl)) {
            buy_p := p;
            buy_lvl := lvl;
            next_buy_lvl := false;
          };
          case _ return await* trim(caller, sub, env);
        } else return await* trim(caller, sub, env);
      } else ();

      var start_sell_o = true;
      var start_buy_o = true;
      var next_sell_o = true;
      var next_buy_o = true;
      var sell_id = 0;
      var buy_id = 0;
      var sell_o : B.Order = {
        created_at = env.now;
        execute = 0;
        block = 0;
        owner = Principal.fromActor(Self);
        sub = Subaccount.get(null);
        is_buy = false;
        price = 0;
        base = Book.newAmount(0);
        expires_at = 0;
        trades = RBTree.empty();
        closed = null;
      };
      var buy_o = { sell_o with is_buy = true };
      label timing while true {
        if (start_sell_o) switch (RBTree.minKey(sell_lvl.orders)) {
          case (?id) {
            sell_id := id;
            sell_o := switch (RBTree.get(orders, Nat.compare, sell_id)) {
              case (?found) found;
              case _ {
                sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
                sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);
                continue timing;
              };
            };
            start_sell_o := false;
          };
          case _ {
            next_sell_lvl := true; // price level is empty
            sell_book := RBTree.delete(sell_book, Nat.compare, sell_p);
            continue pricing;
          };
        } else if (next_sell_o) switch (RBTree.right(sell_lvl.orders, Nat.compare, sell_id + 1)) {
          case (?(id, _)) {
            sell_id := id;
            sell_o := switch (RBTree.get(orders, Nat.compare, sell_id)) {
              case (?found) found;
              case _ {
                sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
                sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);
                continue timing;
              };
            };
            next_sell_o := false;
          };
          case _ {
            next_sell_lvl := true; // price level is busy
            continue pricing;
          };
        };

        if (start_buy_o) switch (RBTree.minKey(buy_lvl.orders)) {
          case (?id) {
            buy_id := id;
            buy_o := switch (RBTree.get(orders, Nat.compare, buy_id)) {
              case (?found) found;
              case _ {
                buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
                buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);
                continue timing;
              };
            };
            start_buy_o := false;
          };
          case _ {
            next_buy_lvl := true;
            buy_book := RBTree.delete(buy_book, Nat.compare, buy_p);
            continue pricing;
          };
        } else if (next_buy_o) switch (RBTree.right(buy_lvl.orders, Nat.compare, buy_id + 1)) {
          case (?(id, _)) {
            buy_id := id;
            buy_o := switch (RBTree.get(orders, Nat.compare, buy_id)) {
              case (?found) found;
              case _ {
                buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
                buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);
                continue timing;
              };
            };
            next_buy_o := false;
          };
          case _ {
            next_buy_lvl := true;
            continue pricing;
          };
        };

        if (sell_id == buy_id) return rebuild("sell id (" # debug_show sell_id # ") is equal to buy id");
        if (sell_o.is_buy) return rebuild("buy order (" # debug_show sell_id # ") is on sell book");
        if (sell_o.price != sell_p) return rebuild("sell order (" # debug_show sell_id # ")'s price (" # debug_show sell_o.price # ") on the wrong level (" # debug_show sell_p # ")");

        if (not buy_o.is_buy) return rebuild("sell order (" # debug_show buy_id # ") is on buy book");
        if (buy_o.price != buy_p) return rebuild("buy order (" # debug_show buy_id # ")'s price (" # debug_show buy_o.price # ") on the wrong level (" # debug_show buy_p # ")");

        switch (sell_o.closed) {
          case (?cl) {
            if (not Book.isClosing(cl.reason)) {
              sell_lvl := Book.levelDecAmount(sell_lvl, sell_o.base);
              sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
              sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);

              base := Book.decAmount(base, sell_o.base);
              var user = getUser(sell_o.owner);
              var subacc = Book.getSubaccount(user, sell_o.sub);
              subacc := Book.subaccDecBase(subacc, sell_o.base);
              user := Book.saveSubaccount(user, sell_o.sub, subacc);
              user := saveUser(sell_o.owner, user);
            };
            next_sell_o := true;
            continue timing;
          };
          case _ ();
        };
        switch (buy_o.closed) {
          case (?cl) {
            if (not Book.isClosing(cl.reason)) {
              buy_lvl := Book.levelDecAmount(buy_lvl, buy_o.base);
              buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
              buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);

              let o_quote = Book.mulAmount(buy_o.base, buy_p);
              quote := Book.decAmount(quote, o_quote);

              var user = getUser(buy_o.owner);
              var subacc = Book.getSubaccount(user, buy_o.sub);
              subacc := Book.subaccDecQuote(subacc, o_quote);
              user := Book.saveSubaccount(user, buy_o.sub, subacc);
              user := saveUser(buy_o.owner, user);
            };
            next_buy_o := true;
            continue timing;
          };
          case _ ();
        };
        if (sell_o.base.locked > 0) {
          next_sell_o := true;
          continue timing;
        };
        if (buy_o.base.locked > 0) {
          next_buy_o := true;
          continue timing;
        };
        if (sell_o.base.filled >= sell_o.base.initial) {
          let closed = ?{ caller; sub; reason = #FullyFilled; at = env.now };
          sell_o := { sell_o with closed };
          orders := RBTree.insert(orders, Nat.compare, sell_id, sell_o);

          sell_lvl := Book.levelDecAmount(sell_lvl, sell_o.base);
          sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
          sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);

          base := Book.decAmount(base, sell_o.base);

          var user = getUser(sell_o.owner);
          var subacc = Book.getSubaccount(user, sell_o.sub);
          subacc := Book.subaccDecBase(subacc, sell_o.base);
          user := Book.saveSubaccount(user, sell_o.sub, subacc);
          user := saveUser(sell_o.owner, user);
          next_sell_o := true;
          continue timing;
        };
        if (buy_o.base.filled >= buy_o.base.initial) {
          let closed = ?{ caller; sub; reason = #FullyFilled; at = env.now };
          buy_o := { buy_o with closed };
          orders := RBTree.insert(orders, Nat.compare, buy_id, buy_o);

          buy_lvl := Book.levelDecAmount(buy_lvl, buy_o.base);
          buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
          buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);

          let o_quote = Book.mulAmount(buy_o.base, buy_p);
          quote := Book.decAmount(quote, o_quote);

          var user = getUser(buy_o.owner);
          var subacc = Book.getSubaccount(user, buy_o.sub);
          subacc := Book.subaccDecBase(subacc, buy_o.base);
          user := Book.saveSubaccount(user, buy_o.sub, subacc);
          user := saveUser(buy_o.owner, user);

          // todo: add to expiry

          next_buy_o := true;
          continue timing;
        };
        let sell_unfilled = sell_o.base.initial - sell_o.base.filled;
        let sell_unfilled_q = sell_unfilled * sell_o.price;
        let buy_unfilled = buy_o.base.initial - buy_o.base.filled;
        let buy_unfilled_q = buy_unfilled * buy_o.price;
        if (sell_o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, sell_id, sell_o, sell_unfilled, sell_lvl, sell_unfilled_q);
        if (buy_o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, buy_id, buy_o, buy_unfilled, buy_lvl, buy_unfilled_q);
        if (sell_unfilled < env.min_base_amount or sell_unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, sell_id, sell_o, sell_unfilled, sell_lvl, sell_unfilled_q);
        if (buy_unfilled < env.min_base_amount or buy_unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, buy_id, buy_o, buy_unfilled, buy_lvl, buy_unfilled_q);

        let sell_maker = sell_id < buy_id;
        if (sell_o.owner == buy_o.owner /* and sell_o.sub == buy_o.sub  // do not check subaccount since we getUser() for both buyer & seller*/) {
          if (sell_maker) next_sell_o := true else next_buy_o := true;
          continue timing;
        };
        if (sell_o.price > buy_o.price) return await* trim(caller, sub, env);
        let maker_p = if (sell_maker) sell_o.price else buy_o.price;
        let (min_base, min_quote, min_side) = if (sell_unfilled < buy_unfilled) (sell_unfilled, sell_unfilled * maker_p, false) else (buy_unfilled, buy_unfilled * maker_p, true);
        if (min_quote < env.min_quote_amount) {
          if (min_side) next_buy_o := true else next_sell_o := true;
          continue timing;
        };
        var sell_u = getUser(sell_o.owner);
        var buy_u = getUser(buy_o.owner);
        var sell_sub = Book.getSubaccount(sell_u, sell_o.sub);
        var buy_sub = Book.getSubaccount(buy_u, buy_o.sub);
        sell_sub := Book.subaccLockBase(sell_sub, min_base);
        buy_sub := Book.subaccLockQuote(buy_sub, min_quote);
        sell_o := Book.lockOrder(sell_o, min_base);
        buy_o := Book.lockOrder(buy_o, min_base);
        sell_lvl := Book.levelLock(sell_lvl, min_base);
        buy_lvl := Book.levelLock(buy_lvl, min_base);
        base := Book.lockAmount(base, min_base);
        quote := Book.lockAmount(quote, min_quote);

        func saveMatch() {
          orders := RBTree.insert(orders, Nat.compare, sell_id, sell_o);
          orders := RBTree.insert(orders, Nat.compare, buy_id, buy_o);
          sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);
          buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);
          sell_u := Book.saveSubaccount(sell_u, sell_o.sub, sell_sub);
          sell_u := saveUser(sell_o.owner, sell_u);
          buy_u := Book.saveSubaccount(buy_u, buy_o.sub, buy_sub);
          buy_u := saveUser(buy_o.owner, buy_u);
        };
        saveMatch();

        let (amt, amt_q) = if (sell_unfilled < buy_unfilled) (sell_unfilled, sell_unfilled_q) else (buy_unfilled, buy_unfilled_q);
        let (sell_fee, buy_fee) = if (sell_maker) (
          (env.maker_fee_numer * amt_q) / env.fee_denom,
          (env.taker_fee_numer * amt) / env.fee_denom,
        ) else (
          (env.taker_fee_numer * amt_q) / env.fee_denom,
          (env.maker_fee_numer * amt) / env.fee_denom,
        );
        let sell_s = Subaccount.opt(sell_o.sub);
        let sell_a = { owner = sell_o.owner; subaccount = sell_s };
        let buy_s = Subaccount.opt(buy_o.sub);
        let buy_a = { owner = buy_o.owner; subaccount = buy_s };

        let base_i = {
          account = sell_a;
          token = env.base_token_id;
          amount = amt;
          action = #Unlock;
        };
        let quote_i = {
          account = buy_a;
          token = env.quote_token_id;
          amount = amt_q;
          action = #Unlock;
        };
        let instruction_blocks = [
          [base_i, { base_i with action = #Transfer { to = buy_a } }],
          [quote_i, { quote_i with action = #Transfer { to = sell_a } }],
          [{
            quote_i with account = sell_a;
            amount = sell_fee;
            action = #Transfer { to = fee_collector };
          }],
          [{
            base_i with account = buy_a;
            amount = buy_fee;
            action = #Transfer { to = fee_collector };
          }],
        ];
        func unlockMatch() {
          sell_o := Book.unlockOrder(sell_o, amt);
          buy_o := Book.unlockOrder(buy_o, amt);
          base := Book.unlockAmount(base, amt);
          quote := Book.unlockAmount(quote, amt_q);
          sell_lvl := Book.getLevel(sell_book, sell_p);
          sell_lvl := Book.levelUnlock(sell_lvl, amt);
          buy_lvl := Book.getLevel(buy_book, buy_p);
          buy_lvl := Book.levelUnlock(buy_lvl, amt);
          sell_u := getUser(sell_o.owner);
          sell_sub := Book.getSubaccount(sell_u, sell_o.sub);
          sell_sub := Book.subaccUnlockBase(sell_sub, amt);
          buy_u := getUser(buy_o.owner);
          buy_sub := Book.getSubaccount(buy_u, buy_o.sub);
          buy_sub := Book.subaccUnlockQuote(buy_sub, amt_q);
        };
        let exec_ids = switch (await env.vault.vault_execute(instruction_blocks)) {
          case (#Err err) {
            unlockMatch();
            saveMatch();
            return #Err(#TradeFailed { buy = buy_id; sell = sell_id; instruction_blocks; error = err });
          };
          case (#Ok ok) ok;
        };
        unlockMatch();
        let sell_h = {
          id = sell_id;
          base = amt;
          fee_quote = sell_fee;
          execute = exec_ids[0];
          fee_execute = exec_ids[2];
        };
        let buy_h = {
          id = buy_id;
          quote = amt_q;
          fee_base = buy_fee;
          execute = exec_ids[1];
          fee_execute = exec_ids[3];
        };
        let trade = {
          sell = sell_h;
          buy = buy_h;
          at = env.now;
          price = maker_p;
          block = block_id;
        };
        sell_o := Book.fillOrder(sell_o, amt, trade_id);
        buy_o := Book.fillOrder(buy_o, amt, trade_id);
        trades := RBTree.insert(trades, Nat.compare, trade_id, trade);
        trade_id += 1;

        base := Book.fillAmount(base, amt);
        quote := Book.fillAmount(quote, amt_q);
        sell_lvl := Book.levelFill(sell_lvl, amt);
        buy_lvl := Book.levelFill(buy_lvl, amt);
        sell_sub := Book.subaccFillBase(sell_sub, amt);
        buy_sub := Book.subaccFillQuote(buy_sub, amt_q);
        saveMatch();
        // todo: blockify

        // if (not next_sell_o and not next_buy_o)
      };
      if (not next_sell_lvl and not next_buy_lvl) return await* trim(caller, sub, env); // after everything, must be one next
    };

    Error.text("No job available");
  };

  func refundClose(caller : Principal, sub : Blob, env : B.Environment, reason : { #Expired : Null; #AlmostFilled : Null }, oid : Nat, _o : B.Order, unfilled : Nat, _lvl : B.Price, unfilled_q : Nat) : async* B.RunRes {
    var o = _o;
    o := { o with closed = ?{ caller; sub; reason; at = env.now } };
    o := Book.lockOrder(o, unfilled);
    orders := RBTree.insert(orders, Nat.compare, oid, o);

    let account = { owner = o.owner; subaccount = Subaccount.opt(o.sub) };
    let unlock = { account; action = #Unlock };
    var lvl = Book.levelLock(_lvl, unfilled);
    var user = getUser(o.owner);
    var subacc = Book.getSubaccount(user, o.sub);
    let (instruction) = if (o.is_buy) {
      buy_book := Book.saveLevel(buy_book, o.price, lvl);
      subacc := Book.subaccLockQuote(subacc, unfilled_q);
      quote := Book.lockAmount(quote, unfilled_q);
      { unlock with token = env.quote_token_id; amount = unfilled_q };
    } else {
      sell_book := Book.saveLevel(sell_book, o.price, lvl);
      subacc := Book.subaccLockBase(subacc, unfilled);
      base := Book.lockAmount(base, unfilled);
      { unlock with token = env.base_token_id; amount = unfilled };
    };
    user := Book.saveSubaccount(user, o.sub, subacc);
    user := saveUser(o.owner, user);

    let user_bals = await env.vault.vault_locked_balances_of([instruction]);
    if (user_bals[0] < instruction.amount) return Error.text("Reunlock");

    let execute_res = await env.vault.vault_execute([[instruction]]);
    func reunlock(exec_ok : ?Nat) {
      user := getUser(caller);
      subacc := Book.getSubaccount(user, sub);
      if (o.is_buy) {
        lvl := Book.getLevel(buy_book, o.price);
        lvl := Book.levelUnlock(lvl, unfilled);
        buy_book := Book.saveLevel(buy_book, o.price, lvl);
        quote := Book.unlockAmount(quote, unfilled_q);
        subacc := Book.subaccUnlockQuote(subacc, unfilled_q);
      } else {
        lvl := Book.getLevel(sell_book, o.price);
        lvl := Book.levelUnlock(lvl, unfilled);
        sell_book := Book.saveLevel(sell_book, o.price, lvl);
        base := Book.unlockAmount(base, unfilled);
        subacc := Book.subaccUnlockBase(subacc, unfilled);
      };
      o := Book.unlockOrder(o, unfilled);
      let closed = switch exec_ok {
        case (?execute) {
          lvl := Book.levelDelOrder(lvl, oid);
          lvl := Book.levelDecAmount(lvl, o.base);
          if (o.is_buy) {
            buy_book := Book.saveLevel(buy_book, o.price, lvl);
            let o_quote = Book.mulAmount(o.base, o.price);
            quote := Book.decAmount(quote, o_quote);
            subacc := Book.subaccDecQuote(subacc, o_quote);
          } else {
            sell_book := Book.saveLevel(sell_book, o.price, lvl);
            base := Book.decAmount(base, o.base);
            subacc := Book.subaccDecBase(subacc, o.base);
          };
          orders_by_expiry := Book.delExpiry(orders_by_expiry, o.expires_at, oid);
          orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expires_at + env.ttl, oid);

          let proof = ?{ block = block_id; execute };
          let rzn = switch reason {
            case (#AlmostFilled _) #AlmostFilled proof;
            case (#Expired _) #Expired proof;
          };
          ?{ caller; sub; at = env.now; reason = rzn };
        };
        case _ null;
      };
      o := { o with closed };
      orders := RBTree.insert(orders, Nat.compare, oid, o);
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(o.owner, user);
    };
    let exec_id = switch execute_res {
      case (#Err err) {
        reunlock(null);
        return Error.text("Exec failed");
      };
      case (#Ok ok) ok[0];
    };
    reunlock(?exec_id);
    // todo: blockify
    Error.text("Pepee");
  };

  func trim(caller : Principal, sub : Blob, env : B.Environment) : async* B.RunRes {
    var round = 0;
    let max_round = 100;
    label trimming while (round <= max_round) {
      let (exp_t, exp_ids) = switch (RBTree.min(orders_by_expiry)) {
        case (?found) found;
        case _ break trimming;
      };
      while (round <= max_round) {
        round += 1;
        let id = switch (RBTree.minKey(exp_ids)) {
          case (?min) min;
          case _ {
            orders_by_expiry := RBTree.delete(orders_by_expiry, Nat64.compare, exp_t);
            continue trimming;
          };
        };
        var o = switch (RBTree.get(orders, Nat.compare, id)) {
          case (?found) found;
          case _ {
            let missing_o = RBTree.delete(exp_ids, Nat.compare, id);
            orders_by_expiry := Book.saveExpiries(orders_by_expiry, exp_t, missing_o);
            continue trimming;
          };
        };
        let is_open = switch (o.closed) {
          case (?cl) if (Book.isClosing(cl.reason)) break trimming else false;
          case _ true;
        };
        if (is_open) {
          if (o.base.locked > 0) break trimming;
          if (o.base.filled >= o.base.initial) {
            let closed = ?{ caller; sub; reason = #FullyFilled; at = env.now };
            o := { o with closed };
            orders := RBTree.insert(orders, Nat.compare, id, o);

            var user = getUser(o.owner);
            var subacc = Book.getSubaccount(user, o.sub);
            if (o.is_buy) {
              var lvl = Book.getLevel(buy_book, o.price);
              lvl := Book.levelDecAmount(lvl, o.base);
              lvl := Book.levelDelOrder(lvl, id);
              buy_book := Book.saveLevel(buy_book, o.price, lvl);

              base := Book.decAmount(base, o.base);
              subacc := Book.subaccDecBase(subacc, o.base);
            } else {
              var lvl = Book.getLevel(sell_book, o.price);
              lvl := Book.levelDecAmount(lvl, o.base);
              lvl := Book.levelDelOrder(lvl, id);
              sell_book := Book.saveLevel(sell_book, o.price, lvl);

              let o_quote = Book.mulAmount(o.base, o.price);
              quote := Book.decAmount(base, o_quote);
              subacc := Book.subaccDecQuote(subacc, o_quote);
            };
            user := Book.saveSubaccount(user, o.sub, subacc);
            user := saveUser(o.owner, user);

            orders_by_expiry := Book.delExpiry(orders_by_expiry, o.expires_at, id);
            orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expires_at + env.ttl, id);

            continue trimming;
          };
          let unfilled = o.base.initial - o.base.filled;
          let unfilled_q = unfilled * o.price;
          var lvl = if (o.is_buy) Book.getLevel(buy_book, o.price) else Book.getLevel(sell_book, o.price);
          if (o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, id, o, unfilled, lvl, unfilled_q);
          if (unfilled < env.min_base_amount or unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, id, o, unfilled, lvl, unfilled_q);
        } else {
          if (o.expires_at < exp_t and exp_t < env.now) {
            orders := RBTree.delete(orders, Nat.compare, id);
            var user = getUser(o.owner);
            var subacc = Book.getSubaccount(user, o.sub);
            subacc := Book.subaccDelOrder(subacc, id);
            user := Book.saveSubaccount(user, o.sub, subacc);
            user := saveUser(o.owner, user);
            continue trimming; // delete from ttl
          } else {
            orders_by_expiry := Book.delExpiry(orders_by_expiry, o.expires_at, id);
            orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expires_at + env.ttl, id);
          };
        };
        break trimming;
      };
    };
    label trimming while (round <= max_round) {
      let (id, tr) = switch (RBTree.min(trades)) {
        case (?min) min;
        case _ break trimming;
      };
      round += 1;
      switch (RBTree.get(orders, Nat.compare, tr.sell.id), RBTree.get(orders, Nat.compare, tr.buy.id)) {
        case (null, null) trades := RBTree.delete(trades, Nat.compare, id);
        case _ break trimming;
      };
    };
    // label archiving while (round <= max_round) {
    //   // todo: finish this
    // };
    Error.text("No job available");
  };

};
