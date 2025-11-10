import B "Types";
import Book "Book";
import V "../vault_canister/Types";
import A "../util/motoko/Archive/Types";
import Archive "../util/motoko/Archive/Canister";
import ArchiveL "../util/motoko/Archive";
import ICRC1T "../icrc1_canister/Types";
import ICRC1L "../icrc1_canister/ICRC1";
import RewardToken "../icrc1_canister/main";
import ICRC3T "../util/motoko/ICRC-3/Types";
import ICRC3L "../util/motoko/ICRC-3";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import OptionX "../util/motoko/Option";
import Buffer "mo:base/Buffer";
import Result "../util/motoko/Result";
import Time64 "../util/motoko/Time64";
import Subaccount "../util/motoko/Subaccount";
import LEB128 "mo:leb128";
import MerkleTree "../util/motoko/MerkleTree";
import CertifiedData "mo:base/CertifiedData";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Cycles "mo:core/Cycles";

shared (install) persistent actor class Canister(
  deploy : {
    #Init : {
      max_order_batch : Nat;
      id : {
        vault : Principal;
        base : Principal;
        quote : Principal;
      };
      memo : { min : Nat; max : Nat };
      fee : {
        collector : Principal;
        numer : {
          maker : Nat;
          taker : Nat;
        };
        denom : Nat;
        close : { base : Nat; quote : Nat };
      };
      secs : {
        ttl : Nat;
        tx_window : Nat;
        permitted_drift : Nat;
        order_expiry : { min : Nat; max : Nat };
      };
      reward : {
        token : Principal;
        multiplier : Nat;
      };
      archive : {
        max_update_batch : Nat;
        min_creation_tcycles : Nat;
      };
      query_max : { batch : Nat; take : Nat };
    };
    #Upgrade;
  }
) = Self {
  var meta : Value.Metadata = RBTree.empty();
  switch deploy {
    case (#Init i) {
      meta := Value.setNat(meta, B.MAX_ORDER_BATCH, ?i.max_order_batch);
      meta := Value.setPrincipal(meta, B.VAULT, ?i.id.vault);
      meta := Value.setPrincipal(meta, B.BASE_TOKEN, ?i.id.base);
      meta := Value.setPrincipal(meta, B.QUOTE_TOKEN, ?i.id.quote);
      meta := Value.setNat(meta, B.MIN_MEMO, ?i.memo.min);
      meta := Value.setNat(meta, B.MAX_MEMO, ?i.memo.max);
      meta := Value.setPrincipal(meta, B.FEE_COLLECTOR, ?i.fee.collector);
      meta := Value.setNat(meta, B.MAKER_FEE_NUMER, ?i.fee.numer.maker);
      meta := Value.setNat(meta, B.TAKER_FEE_NUMER, ?i.fee.numer.taker);
      meta := Value.setNat(meta, B.TRADING_FEE_DENOM, ?i.fee.denom);
      meta := Value.setNat(meta, B.TTL, ?i.secs.ttl);
      meta := Value.setNat(meta, B.TX_WINDOW, ?i.secs.tx_window);
      meta := Value.setNat(meta, B.PERMITTED_DRIFT, ?i.secs.permitted_drift);
      meta := Value.setNat(meta, B.MIN_ORDER_EXPIRY, ?i.secs.order_expiry.min);
      meta := Value.setNat(meta, B.MAX_ORDER_EXPIRY, ?i.secs.order_expiry.max);
      meta := Value.setNat(meta, B.CANCEL_FEE_BASE, ?i.fee.close.base);
      meta := Value.setNat(meta, B.CANCEL_FEE_QUOTE, ?i.fee.close.quote);
      meta := Value.setPrincipal(meta, B.REWARD_TOKEN, ?i.reward.token);
      meta := Value.setNat(meta, B.REWARD_MULTIPLIER, ?i.reward.multiplier);
      meta := Value.setNat(meta, B.MAX_TAKE, ?i.query_max.take);
      meta := Value.setNat(meta, B.MAX_QUERY_BATCH, ?i.query_max.batch);

      meta := Value.setNat(meta, A.MAX_UPDATE_BATCH_SIZE, ?i.archive.max_update_batch);
      meta := Value.setNat(meta, A.MIN_TCYCLES, ?i.archive.min_creation_tcycles);
    };
    case _ ();
  };

  var tip_cert = MerkleTree.empty();
  func updateTipCert() = CertifiedData.set(MerkleTree.treeHash(tip_cert)); // also call this on deploy.init
  system func postupgrade() = updateTipCert(); // https://gist.github.com/nomeata/f325fcd2a6692df06e38adedf9ca1877

  var users : B.Users = RBTree.empty();

  var order_id = 0;
  var orders = RBTree.empty<Nat, B.Order>();
  var orders_by_expiry : B.Expiries = RBTree.empty();

  var sell_book : B.Book = RBTree.empty();
  var buy_book : B.Book = RBTree.empty();

  var trade_id = 0;
  var trades = RBTree.empty<Nat, B.Trade>();

  var place_dedupes : B.PlaceDedupes = RBTree.empty();

  var blocks = RBTree.empty<Nat, A.Block>();

  var reward_id = 0;
  var rewards = RBTree.empty<Nat, (ICRC1T.Enqueue, locked : Bool)>();
  var prev_build = null : ?Nat;

  public shared query func book_base_token_id() : async ?Principal = async Value.metaPrincipal(meta, B.BASE_TOKEN);
  public shared query func book_quote_token_id() : async ?Principal = async Value.metaPrincipal(meta, B.QUOTE_TOKEN);
  // todo: add buy/sell maker/taker
  public shared query func book_maker_fee_numerator() : async Nat = async Value.getNat(meta, B.MAKER_FEE_NUMER, 0);
  public shared query func book_taker_fee_numerator() : async Nat = async Value.getNat(meta, B.TAKER_FEE_NUMER, 0);
  public shared query func book_trading_fee_denominator() : async Nat = async Value.getNat(meta, B.TRADING_FEE_DENOM, 0);
  public shared query func book_min_order_expiry() : async Nat = async Value.getNat(meta, B.MIN_ORDER_EXPIRY, 0);
  public shared query func book_max_order_expiry() : async Nat = async Value.getNat(meta, B.MAX_ORDER_EXPIRY, 0);
  public shared query func book_open_fee_quote() : async Nat = async Value.getNat(meta, B.PLACE_FEE_QUOTE, 0);
  public shared query func book_open_fee_base() : async Nat = async Value.getNat(meta, B.PLACE_FEE_BASE, 0);
  public shared query func book_close_fee_quote() : async Nat = async Value.getNat(meta, B.CANCEL_FEE_QUOTE, 0);
  public shared query func book_close_fee_base() : async Nat = async Value.getNat(meta, B.CANCEL_FEE_BASE, 0);

  public shared query func book_buy_orders_by(acc : ICRC1T.Account, prev : ?Nat, take : ?Nat) : async [Nat] {
    let subacc = Book.getSubaccount(getUser(acc.owner), Subaccount.get(acc.subaccount));
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(subacc.buys));
    RBTree.pageKey(subacc.buys, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_sell_orders_by(acc : ICRC1T.Account, prev : ?Nat, take : ?Nat) : async [Nat] {
    let subacc = Book.getSubaccount(getUser(acc.owner), Subaccount.get(acc.subaccount));
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(subacc.sells));
    RBTree.pageKey(subacc.sells, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_buy_prices_by(acc : ICRC1T.Account, prev : ?Nat, take : ?Nat) : async [(Nat, Nat)] {
    let subacc = Book.getSubaccount(getUser(acc.owner), Subaccount.get(acc.subaccount));
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(subacc.buy_lvls));
    RBTree.pageReverse(subacc.buy_lvls, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_sell_prices_by(acc : ICRC1T.Account, prev : ?Nat, take : ?Nat) : async [(Nat, Nat)] {
    let subacc = Book.getSubaccount(getUser(acc.owner), Subaccount.get(acc.subaccount));
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(subacc.sell_lvls));
    RBTree.page(subacc.sell_lvls, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_order_ids(prev : ?Nat, take : ?Nat) : async [Nat] {
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(orders));
    RBTree.pageKey(orders, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_order_sides_of(oids : [Nat]) : async [?Bool] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Bool>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.is_buy);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_prices_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.price);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_closed_timestamps_of(oids : [Nat]) : async [?Nat64] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat64>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) switch (found.closed) {
          case (?yes) res.add(?yes.at);
          case _ res.add(null);
        };
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_closed_reasons_of(oids : [Nat]) : async [?B.CloseReason] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?B.CloseReason>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) switch (found.closed) {
          case (?yes) res.add(?yes.reason);
          case _ res.add(null);
        };
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_expiry_timestamps_of(oids : [Nat]) : async [?Nat64] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat64>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.expires_at);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_initial_amounts_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.base.initial);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_locked_amounts_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.base.locked);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_filled_amounts_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.base.filled);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_owners_of(oids : [Nat]) : async [?Principal] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Principal>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.owner);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_subaccounts_of(oids : [Nat]) : async [?Blob] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Blob>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(Subaccount.opt(found.sub));
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_created_timestamps_of(oids : [Nat]) : async [?Nat64] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat64>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.created_at);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_blocks_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.block);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_executions_of(oids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, oids.size()), oids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (oid in oids.vals()) {
      switch (RBTree.get(orders, Nat.compare, oid)) {
        case (?found) res.add(?found.execute);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_order_trades_of(oid : Nat, prev : ?Nat, take : ?Nat) : async [Nat] {
    let o = switch (RBTree.get(orders, Nat.compare, oid)) {
      case (?found) found;
      case _ return [];
    };
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(o.trades));
    RBTree.pageKey(o.trades, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_trade_ids(prev : ?Nat, take : ?Nat) : async [Nat] {
    let maxt = Value.getNat(meta, B.MAX_TAKE, RBTree.size(trades)); // newest to oldest
    RBTree.pageKeyReverse(trades, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_trade_sell_ids_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.sell.id);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_sell_bases_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.sell.base);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_sell_fee_quotes_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.sell.fee_quote);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_sell_executions_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.sell.execute);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_sell_fee_executions_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.sell.fee_execute);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_buy_ids_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.buy.id);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_buy_quotes_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.buy.quote);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_buy_fee_bases_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.buy.fee_base);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_buy_executions_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.buy.execute);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_buy_fee_executions_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.buy.fee_execute);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_timestamps_of(tids : [Nat]) : async [?Nat64] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat64>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.at);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_trade_blocks_of(tids : [Nat]) : async [?Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, tids.size()), tids.size());
    let res = Buffer.Buffer<?Nat>(maxt);
    label batching for (tid in tids.vals()) {
      switch (RBTree.get(trades, Nat.compare, tid)) {
        case (?found) res.add(?found.block);
        case _ res.add(null);
      };
      if (res.size() >= maxt) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func book_ask_prices(prev : ?Nat, take : ?Nat) : async [Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, RBTree.size(sell_book)), RBTree.size(sell_book));
    RBTree.pageKey(sell_book, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_bid_prices(prev : ?Nat, take : ?Nat) : async [Nat] {
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, RBTree.size(buy_book)), RBTree.size(buy_book));
    RBTree.pageKeyReverse(buy_book, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_asks_at(price : Nat, prev : ?Nat, take : ?Nat) : async [Nat] {
    let lvl = Book.getLevel(sell_book, price);
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, RBTree.size(lvl)), RBTree.size(lvl));
    RBTree.pageKey(lvl, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func book_bids_at(price : Nat, prev : ?Nat, take : ?Nat) : async [Nat] {
    let lvl = Book.getLevel(buy_book, price);
    let maxt = Nat.min(Value.getNat(meta, B.MAX_TAKE, RBTree.size(lvl)), RBTree.size(lvl));
    RBTree.pageKey(lvl, Nat.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  // public shared query func book_base_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func book_quote_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func book_open(arg : B.PlaceArg) : async B.PlaceRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let max_oid = RBTree.maxKey(orders);
    if (max_oid != null and max_oid != prev_build) return Error.text("Orderbook needs rebuilding. Please call `book_run`");

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
      let o_expiry = Option.get(o.expires_at, env.max_expires_at);
      if (o_expiry < env.min_expires_at) return #Err(#ExpiresTooSoon { index; minimum_expires_at = env.min_expires_at });
      if (o_expiry > env.max_expires_at) return #Err(#ExpiresTooLate { index; maximum_expires_at = env.max_expires_at });

      if (o.price < env.min_price) return #Err(#PriceTooLow { index; minimum_price = env.min_price });

      let nearest_price = Book.nearTick(o.price, env.min_price);
      if (o.price != nearest_price) return #Err(#PriceTooFar { index; nearest_price });

      let min_amount = Nat.max(env.min_base_amount, env.min_quote_amount / o.price);
      if (o.amount < min_amount) return #Err(#AmountTooLow { index; minimum_amount = min_amount });

      let nearest_amount = Book.nearTick(o.amount, env.min_base_amount);
      if (o.amount != nearest_amount) return #Err(#AmountTooFar { index; nearest_amount });

      let instruction = if (o.is_buy) {
        switch (RBTree.get(lbuys, Nat.compare, o.price)) {
          case (?found) return #Err(#DuplicatePrice { indexes = [found.index, index] });
          case _ ();
        };
        let lq = o.amount * o.price / env.quote_power;
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

    let min_gsell = RBTree.min(subacc.sell_lvls);
    let max_gbuy = RBTree.max(subacc.buy_lvls);
    switch (min_lsell, max_gbuy) {
      case (?(lsell_price, lsell), ?(gbuy_price, gbuy)) if (lsell_price <= gbuy_price) return #Err(#PriceTooLow { lsell with minimum_price = gbuy_price });
      case _ ();
    };
    switch (max_lbuy, min_gsell) {
      case (?(lbuy_price, lbuy), ?(gsell_price, gsell)) if (lbuy_price >= gsell_price) return #Err(#PriceTooHigh { lbuy with maximum_price = gsell_price });
      case _ ();
    };
    for ((lsell_price, lsell) in RBTree.entries(lsells)) switch (RBTree.get(subacc.sell_lvls, Nat.compare, lsell_price)) {
      case (?found) return #Err(#PriceUnavailable { lsell with order_id = found });
      case _ ();
    };
    for ((lbuy_price, lbuy) in RBTree.entries(lbuys)) switch (RBTree.get(subacc.buy_lvls, Nat.compare, lbuy_price)) {
      case (?found) return #Err(#PriceUnavailable { lbuy with order_id = found });
      case _ ();
    };
    let user_bals = await env.vault.vault_unlocked_balances_of([{ account = user_acc; token = env.base_token_id }, { account = user_acc; token = env.quote_token_id }]);
    Debug.print(debug_show { lbase; lquote });
    if (user_bals[0] < lbase or user_bals[1] < lquote) return #Err(#InsufficientBalance { base_balance = user_bals[0]; quote_balance = user_bals[1] });
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, arg, env, arg.created_at)) {
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
    let oids = Buffer.Buffer<Nat>(arg.orders.size());
    let ovalues = Buffer.Buffer<Value.Type>(arg.orders.size());
    let (block_id, phash) = ArchiveL.getPhash(blocks);
    func newOrder(o : { index : Nat; expiry : Nat64 }) : B.Order {
      let new_order = Book.newOrder(exec_ids[o.index], block_id, env.now, { arg.orders[o.index] with owner = caller; sub; expires_at = o.expiry });
      orders := RBTree.insert(orders, Nat.compare, order_id, new_order);
      prev_build := ?order_id;
      oids.add(order_id);
      ovalues.add(Book.valueOpen(order_id, new_order));

      orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expiry, order_id);
      new_order;
    };
    for ((o_price, o) in RBTree.entries(lsells)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(sell_book, o_price);
      price := Book.levelNewOrder(price, order_id);
      sell_book := Book.saveLevel(sell_book, o_price, price);
      subacc := Book.subaccNewSell(subacc, order_id);
      subacc := Book.subaccNewSellLevel(subacc, order_id, new_order);
      order_id += 1;
    };
    for ((o_price, o) in RBTree.entriesReverse(lbuys)) {
      let new_order = newOrder(o);
      var price = Book.getLevel(buy_book, o_price);
      price := Book.levelNewOrder(price, order_id);
      buy_book := Book.saveLevel(buy_book, o_price, price);
      subacc := Book.subaccNewBuy(subacc, order_id);
      subacc := Book.subaccNewBuyLevel(subacc, order_id, new_order);
      order_id += 1;
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    if (arg.created_at != null) place_dedupes := RBTree.insert(place_dedupes, Book.dedupePlace, (caller, arg), block_id);

    let val = Book.valueOpens(caller, sub, arg.memo, arg.created_at, env.now, Buffer.toArray(ovalues), phash);
    newBlock(block_id, val);
    #Ok(Buffer.toArray(oids));
  };

  public shared ({ caller }) func book_close(arg : B.CancelArg) : async B.CancelRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let max_oid = RBTree.maxKey(orders);
    if (max_oid != null and max_oid != prev_build) return Error.text("Orderbook needs rebuilding. Please call `book_run`");

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
          let o_quote = unfilled * o.price / env.quote_power;
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
        o := { o with closed = ?{ reason; at = env.now } };
        refundables := RBTree.insert(refundables, Nat.compare, oid, { index; data = o; reason; instruction_index });
      } else {
        let closed = ?{ reason = #FullyFilled; at = env.now };
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
        if (o.data.is_buy) {
          var pr = Book.getLevel(buy_book, o.data.price);
          pr := Book.levelDelOrder(pr, oid);
          buy_book := Book.saveLevel(buy_book, o.data.price, pr);
          subacc := Book.subaccDelBuyLevel(subacc, o.data);
        } else {
          var pr = Book.getLevel(sell_book, o.data.price);
          pr := Book.levelDelOrder(pr, oid);
          sell_book := Book.saveLevel(sell_book, o.data.price, pr);

          subacc := Book.subaccDelSellLevel(subacc, o.data);
        };
        orders_by_expiry := Book.delExpiry(orders_by_expiry, o.data.expires_at, oid);
        orders_by_expiry := Book.newExpiry(orders_by_expiry, o.data.expires_at + env.ttl, oid);
      };
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(caller, user);
    };
    if (RBTree.size(refundables) == 0) return #Err(#Closed { index = 0; at = env.now });

    for ((oid, o) in RBTree.entries(refundables)) {
      orders := RBTree.insert(orders, Nat.compare, oid, o.data);
      if (o.data.is_buy) {
        var price = Book.getLevel(buy_book, o.data.price);
        buy_book := Book.saveLevel(buy_book, o.data.price, price);
      } else {
        var price = Book.getLevel(sell_book, o.data.price);
        sell_book := Book.saveLevel(sell_book, o.data.price, price);
      };
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    func unlock<T>(t : T) : T {
      user := getUser(caller);
      subacc := Book.getSubaccount(user, sub);
      for ((oid, o) in RBTree.entries(refundables)) {
        if (o.data.is_buy) {
          var pr = Book.getLevel(buy_book, o.data.price);
          buy_book := Book.saveLevel(buy_book, o.data.price, pr);
          var o_quote = o.data.base.locked * o.data.price / env.quote_power;
        } else {
          var pr = Book.getLevel(sell_book, o.data.price);
          sell_book := Book.saveLevel(sell_book, o.data.price, pr);
        };
        var order = Book.unlockOrder(o.data, o.data.base.locked);
        order := { order with closed = null };
        orders := RBTree.insert(orders, Nat.compare, oid, order);
      };
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(caller, user);
      t;
    };

    let user_bals = await env.vault.vault_locked_balances_of([{ account = user_acc; token = env.base_token_id }, { account = user_acc; token = env.quote_token_id }]);
    if (user_bals[0] < lbase or user_bals[1] < lquote) return unlock(#Err(#InsufficientBalance { base_balance = user_bals[0]; quote_balance = user_bals[1] }));

    let instruction_blocks = Buffer.toArray(refunds_buff);
    let exec_ids = switch (await env.vault.vault_execute(instruction_blocks)) {
      case (#Err err) return unlock(#Err(#ExecutionFailed { instruction_blocks; error = err }));
      case (#Ok ok) ok;
    };
    user := getUser(caller);
    subacc := Book.getSubaccount(user, sub);
    let (block_id, phash) = ArchiveL.getPhash(blocks);
    let ovalues = Buffer.Buffer<Value.Type>(RBTree.size(refundables));
    for ((oid, o) in RBTree.entries(refundables)) {
      let execute = exec_ids[o.instruction_index];
      if (o.data.is_buy) {
        var pr = Book.getLevel(buy_book, o.data.price);
        pr := Book.levelDelOrder(pr, oid);
        buy_book := Book.saveLevel(buy_book, o.data.price, pr);
        let quote_locked = o.data.base.locked * o.data.price / env.quote_power;
        subacc := Book.subaccDelBuyLevel(subacc, o.data);
        let fee = if (o.reason == #Canceled null) fee_quote else 0;
        ovalues.add(Book.valueClose(oid, "quote", quote_locked, fee, execute));
      } else {
        var pr = Book.getLevel(sell_book, o.data.price);
        pr := Book.levelDelOrder(pr, oid);
        sell_book := Book.saveLevel(sell_book, o.data.price, pr);
        subacc := Book.subaccDelSellLevel(subacc, o.data);
        let fee = if (o.reason == #Canceled null) fee_base else 0;
        ovalues.add(Book.valueClose(oid, "base", o.data.base.locked, fee, execute));
      };
      orders_by_expiry := Book.delExpiry(orders_by_expiry, o.data.expires_at, oid);
      orders_by_expiry := Book.newExpiry(orders_by_expiry, o.data.expires_at + env.ttl, oid);

      let proof = ?{ block = block_id; execute };
      let reason = switch (o.reason) {
        case (#AlmostFilled _) #AlmostFilled proof;
        case (#Canceled _) #Canceled proof;
        case (#Expired _) #Expired proof;
      };
      let closed = ?{ at = env.now; reason };
      var order = Book.unlockOrder(o.data, o.data.base.locked);
      order := { order with closed };
      orders := RBTree.insert(orders, Nat.compare, oid, order);
    };
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);
    let val = Book.valueCloses(arg.memo, env.now, Buffer.toArray(ovalues), phash);
    newBlock(block_id, val);
    #Ok block_id;
  };

  func getUser(p : Principal) : B.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ RBTree.empty();
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
  func checkIdempotency(caller : Principal, arg : B.PlaceArg, { now : Nat64; tx_window : Nat64; permitted_drift : Nat64 }, created_at : ?Nat64) : Result.Type<(), { #CreatedInFuture : { vault_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> = switch (created_at) {
    case (?created_time) {
      let start_time = now - tx_window - permitted_drift;
      if (created_time < start_time) return #Err(#TooOld);
      let end_time = now + permitted_drift;
      if (created_time > end_time) return #Err(#CreatedInFuture { vault_time = now });
      switch (RBTree.get(place_dedupes, Book.dedupePlace, (caller, arg))) {
        case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
        case _ #Ok;
      };
    };
    case _ #Ok;
  };

  public shared ({ caller }) func book_run(arg : B.RunArg) : async B.RunRes {
    if (not Value.getBool(meta, B.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acc = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acc)) return Error.text("Caller account is not valid");
    let sub = Subaccount.get(arg.subaccount);
    let env = switch (await* Book.getEnvironment(meta)) {
      case (#Err err) return #Err err;
      case (#Ok ok) ok;
    };
    meta := env.meta;
    switch prev_build {
      case (?built_until) switch (RBTree.maxKey(orders)) {
        case (?max_oid) switch (Nat.compare(built_until, max_oid)) {
          case (#less) build();
          case _ await* trim(caller, sub, env);
        };
        case _ Error.text("Empty orders");
      };
      case _ {
        users := RBTree.empty(); // rebuild everything using orders
        orders_by_expiry := RBTree.empty();
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
      if (is_open) {
        if (o.is_buy) {
          var pr = Book.getLevel(buy_book, o.price);
          pr := Book.levelNewOrder(pr, oid);
          buy_book := Book.saveLevel(buy_book, o.price, pr);
          subacc := Book.subaccNewBuy(subacc, oid);
          subacc := Book.subaccNewBuyLevel(subacc, oid, o);
        } else {
          var pr = Book.getLevel(sell_book, o.price);
          pr := Book.levelNewOrder(pr, oid);
          sell_book := Book.saveLevel(sell_book, o.price, pr);
          subacc := Book.subaccNewSell(subacc, oid);
          subacc := Book.subaccNewSellLevel(subacc, oid, o);
        };
      };
      user := Book.saveSubaccount(user, o.sub, subacc);
      user := saveUser(o.owner, user);

      prev_build := ?oid;
      res.add(oid);
    };
    Error.text("Built: " # debug_show (Buffer.toArray(res)));
  };

  func trim(caller : Principal, sub : Blob, env : B.Environment) : async* B.RunRes {
    var round = 0;
    let max_round = 100;
    let start_time = env.now - env.tx_window - env.permitted_drift;
    label trimming while (round <= max_round) {
      let ((p, arg), _) = switch (RBTree.min(place_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at, ?start_time, Nat64.compare)) {
        case (#less) place_dedupes := RBTree.delete(place_dedupes, Book.dedupePlace, (p, arg));
        case _ break trimming;
      };
    };
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
            let closed = ?{ reason = #FullyFilled; at = env.now };
            o := { o with closed };
            orders := RBTree.insert(orders, Nat.compare, id, o);

            var user = getUser(o.owner);
            var subacc = Book.getSubaccount(user, o.sub);
            if (o.is_buy) {
              var lvl = Book.getLevel(buy_book, o.price);
              lvl := Book.levelDelOrder(lvl, id);
              buy_book := Book.saveLevel(buy_book, o.price, lvl);
              subacc := Book.subaccDelBuyLevel(subacc, o);
            } else {
              var lvl = Book.getLevel(sell_book, o.price);
              lvl := Book.levelDelOrder(lvl, id);
              sell_book := Book.saveLevel(sell_book, o.price, lvl);
              subacc := Book.subaccDelSellLevel(subacc, o);
            };
            user := Book.saveSubaccount(user, o.sub, subacc);
            user := saveUser(o.owner, user);

            orders_by_expiry := Book.delExpiry(orders_by_expiry, o.expires_at, id);
            orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expires_at + env.ttl, id);

            continue trimming;
          };
          let unfilled = o.base.initial - o.base.filled;
          let unfilled_q = unfilled * o.price / env.quote_power;
          var lvl = if (o.is_buy) Book.getLevel(buy_book, o.price) else Book.getLevel(sell_book, o.price);
          if (o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, id, o, unfilled, lvl, unfilled_q);
          if (unfilled < env.min_base_amount or unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, id, o, unfilled, lvl, unfilled_q);
        } else {
          if (o.expires_at < exp_t and exp_t < env.now) {
            orders := RBTree.delete(orders, Nat.compare, id);
            var user = getUser(o.owner);
            var subacc = Book.getSubaccount(user, o.sub);
            if (o.is_buy) {
              subacc := Book.subaccDelBuy(subacc, id);
              subacc := Book.subaccDelBuyLevel(subacc, o);
            } else {
              subacc := Book.subaccDelSell(subacc, id);
              subacc := Book.subaccDelSellLevel(subacc, o);
            };
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
    label trimming while (round <= max_round and RBTree.size(rewards) > 0) {
      let reward_token_id = switch (Value.metaPrincipal(meta, B.REWARD_TOKEN)) {
        case (?found) found;
        case _ break trimming;
      };
      let reward_token = actor (Principal.toText(reward_token_id)) : RewardToken.Canister;
      let max_batch = switch (await reward_token.xlt_max_update_batch_size()) {
        case (?found) Nat.max(1, found);
        case _ 1;
      };
      var locks = RBTree.empty<Nat, ICRC1T.Enqueue>();
      round += 1;
      let buff = Buffer.Buffer<ICRC1T.Enqueue>(max_batch);
      label collecting for ((r_id, (r, locked)) in RBTree.entries(rewards)) {
        if (locked) break trimming;
        buff.add(r);
        locks := RBTree.insert(locks, Nat.compare, r_id, r);
        if (RBTree.size(locks) >= max_batch) break collecting;
      };
      for ((r_id, r) in RBTree.entries(locks)) rewards := RBTree.insert(rewards, Nat.compare, r_id, (r, true));
      switch (await reward_token.xlt_enqueue_minting_rounds(Buffer.toArray(buff))) {
        case (#Err err) for ((r_id, r) in RBTree.entries(locks)) rewards := RBTree.insert(rewards, Nat.compare, r_id, (r, false));
        case (#Ok) for ((r_id, r) in RBTree.entries(locks)) rewards := RBTree.delete(rewards, Nat.compare, r_id);
      };
      return Error.text("No work available");
    };
    if (round <= max_round) switch (await* sendBlock()) {
      case (#Ok) return Error.text("No job available");
      case (#Err(#Async err)) return #Err(err);
      case (#Err(#Sync _)) round += 1;
    };
    await* match(caller, sub, env, round, max_round);
  };

  func newBlock(block_id : Nat, val : Value.Type) {
    let valh = Value.hash(val);
    let idh = Blob.fromArray(LEB128.toUnsignedBytes(block_id));
    blocks := RBTree.insert(blocks, Nat.compare, block_id, { val; valh; idh; locked = false });

    tip_cert := MerkleTree.empty();
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_INDEX)], idh);
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_HASH)], valh);
    updateTipCert();
  };

  func sendBlock() : async* Result.Type<(), { #Sync : Error.Generic; #Async : Error.Generic }> {
    var max_batch = Value.getNat(meta, A.MAX_UPDATE_BATCH_SIZE, 0);
    if (max_batch == 0) max_batch := 1;
    if (max_batch > 100) max_batch := 100;
    meta := Value.setNat(meta, A.MAX_UPDATE_BATCH_SIZE, ?max_batch);

    if (RBTree.size(blocks) <= max_batch) return #Err(#Sync(Error.generic("Not enough blocks to archive", 0)));
    var locks = RBTree.empty<Nat, A.Block>();
    let batch_buff = Buffer.Buffer<ICRC3T.BlockResult>(max_batch);
    label collecting for ((b_id, b) in RBTree.entries(blocks)) {
      if (b.locked) return #Err(#Sync(Error.generic("Some blocks are locked for archiving", 0)));
      locks := RBTree.insert(locks, Nat.compare, b_id, b);
      batch_buff.add({ id = b_id; block = b.val });
      if (batch_buff.size() >= max_batch) break collecting;
    };
    for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = true });
    func reunlock<T>(t : T) : T {
      for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = false });
      t;
    };
    let root = switch (Value.metaPrincipal(meta, A.ROOT)) {
      case (?exist) exist;
      case _ switch (await* createArchive(null)) {
        case (#Ok created) created;
        case (#Err err) return reunlock(#Err(#Async(err)));
      };
    };
    let batch = Buffer.toArray(batch_buff);
    let start = batch[0].id;
    var prev_redir : A.Redirect = #Ask(actor (Principal.toText(root)));
    var curr_redir = prev_redir;
    var next_redir = try await (actor (Principal.toText(root)) : Archive.Canister).rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));

    label travelling while true {
      switch (ArchiveL.validateSequence(prev_redir, curr_redir, next_redir)) {
        case (#Err msg) return reunlock(#Err(#Async(Error.generic(msg, 0))));
        case _ ();
      };
      prev_redir := curr_redir;
      curr_redir := next_redir;
      next_redir := switch next_redir {
        case (#Ask cnstr) try await cnstr.rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));
        case (#Add cnstr) {
          let cnstr_id = Principal.fromActor(cnstr);
          try {
            switch (await cnstr.rb_archive_add(batch)) {
              case (#Err(#InvalidDestination r)) r;
              case (#Err(#UnexpectedBlock x)) return reunlock(#Err(#Async(Error.generic("UnexpectedBlock: " # debug_show x, 0))));
              case (#Err(#MinimumBlockViolation x)) return reunlock(#Err(#Async(Error.generic("MinimumBlockViolation: " # debug_show x, 0))));
              case (#Err(#BatchTooLarge x)) return reunlock(#Err(#Async(Error.generic("BatchTooLarge: " # debug_show x, 0))));
              case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
              case (#Ok) break travelling;
            };
          } catch ee #Create(actor (Principal.toText(cnstr_id)));
        };
        case (#Create cnstr) {
          let cnstr_id = Principal.fromActor(cnstr);
          try {
            let slave = switch (await* createArchive(?cnstr_id)) {
              case (#Err err) return reunlock(#Err(#Async(err)));
              case (#Ok created) created;
            };
            switch (await cnstr.rb_archive_create(slave)) {
              case (#Err(#InvalidDestination r)) r;
              case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
              case (#Ok new_root) {
                meta := Value.setPrincipal(meta, A.ROOT, ?new_root);
                meta := Value.setPrincipal(meta, A.STANDBY, null);
                #Add(actor (Principal.toText(slave)));
              };
            };
          } catch ee return reunlock(#Err(#Async(Error.convert(ee))));
        };
      };
    };
    for (b in batch.vals()) blocks := RBTree.delete(blocks, Nat.compare, b.id);
    #Ok;
  };

  func createArchive(master : ?Principal) : async* Result.Type<Principal, Error.Generic> {
    switch (Value.metaPrincipal(meta, A.STANDBY)) {
      case (?standby) return try switch (await (actor (Principal.toText(standby)) : Archive.Canister).rb_archive_initialize(master)) {
        case (#Err err) #Err err;
        case _ #Ok standby;
      } catch e #Err(Error.convert(e));
      case _ ();
    };
    var archive_tcycles = Value.getNat(meta, A.MIN_TCYCLES, 0);
    if (archive_tcycles < 3) archive_tcycles := 3;
    if (archive_tcycles > 10) archive_tcycles := 10;
    meta := Value.setNat(meta, A.MIN_TCYCLES, ?archive_tcycles);

    let trillion = 10 ** 12;
    let cost = archive_tcycles * trillion;
    let reserve = 2 * trillion;
    if (Cycles.balance() < cost + reserve) return Error.text("Insufficient cycles balance to create a new archive");

    try {
      let new_canister = await (with cycles = cost) Archive.Canister(master);
      #Ok(Principal.fromActor(new_canister));
    } catch e #Err(Error.convert(e));
  };

  func rebuild(msg : Text) : Error.Result {
    prev_build := null;
    Error.text("Rebuilding: " # msg);
  };
  func match(caller : Principal, sub : Blob, env : B.Environment, _round : Nat, max_round : Nat) : async* B.RunRes {
    let fee_collector = getFeeCollector();
    var start_sell_lvl = true;
    var start_buy_lvl = true;
    var next_sell_lvl = false;
    var next_buy_lvl = false;
    var sell_p = 0;
    var buy_p = 0;
    var sell_lvl = Book.getLevel(RBTree.empty(), 0);
    var buy_lvl = Book.getLevel(RBTree.empty(), 0);
    var round = _round;
    label pricing while (round <= max_round) {
      if (start_sell_lvl) switch (RBTree.min(sell_book)) {
        case (?(p, lvl)) {
          sell_p := p;
          sell_lvl := lvl;
          start_sell_lvl := false;
        };
        case _ return Error.text("Sell book is empty");
      } else if (next_sell_lvl) switch (RBTree.right(sell_book, Nat.compare, sell_p + 1)) {
        case (?(p, lvl)) {
          sell_p := p;
          sell_lvl := lvl;
          next_sell_lvl := false;
        };
        case _ return Error.text("Reached the end of sell book");
      };

      if (start_buy_lvl) switch (RBTree.max(buy_book)) {
        case (?(p, lvl)) {
          buy_p := p;
          buy_lvl := lvl;
          start_buy_lvl := false;
        };
        case _ return Error.text("Buy book is empty");
      } else if (next_buy_lvl) {
        if (buy_p > 0) switch (RBTree.left(buy_book, Nat.compare, buy_p - 1)) {
          case (?(p, lvl)) {
            buy_p := p;
            buy_lvl := lvl;
            next_buy_lvl := false;
          };
          case _ return Error.text("Reached the end of buy book");
        } else return Error.text("Reached the bottom of buy book");
      };

      var start_sell_o = true;
      var start_buy_o = true;
      var next_sell_o = true;
      var next_buy_o = true;
      var sell_id = 0;
      var buy_id = 0;
      var sell_o = Book.defaultOrder(Principal.fromActor(Self), Subaccount.get(null), false, env.now);
      var buy_o = { sell_o with is_buy = true };
      label timing while (round <= max_round) {
        if (start_sell_o) switch (RBTree.minKey(sell_lvl)) {
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
        } else if (next_sell_o) switch (RBTree.right(sell_lvl, Nat.compare, sell_id + 1)) {
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

        if (start_buy_o) switch (RBTree.minKey(buy_lvl)) {
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
        } else if (next_buy_o) switch (RBTree.right(buy_lvl, Nat.compare, buy_id + 1)) {
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
        round += 1;

        if (sell_id == buy_id) return rebuild("sell id (" # debug_show sell_id # ") is equal to buy id");
        if (sell_o.is_buy) return rebuild("buy order (" # debug_show sell_id # ") is on sell book");
        if (sell_o.price != sell_p) return rebuild("sell order (" # debug_show sell_id # ")'s price (" # debug_show sell_o.price # ") on the wrong level (" # debug_show sell_p # ")");

        if (not buy_o.is_buy) return rebuild("sell order (" # debug_show buy_id # ") is on buy book");
        if (buy_o.price != buy_p) return rebuild("buy order (" # debug_show buy_id # ")'s price (" # debug_show buy_o.price # ") on the wrong level (" # debug_show buy_p # ")");

        switch (sell_o.closed) {
          case (?cl) {
            if (not Book.isClosing(cl.reason)) {
              sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
              sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);

              var user = getUser(sell_o.owner);
              var subacc = Book.getSubaccount(user, sell_o.sub);
              subacc := Book.subaccDelSellLevel(subacc, sell_o);
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
              buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
              buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);
              var user = getUser(buy_o.owner);
              var subacc = Book.getSubaccount(user, buy_o.sub);
              subacc := Book.subaccDelBuyLevel(subacc, buy_o);
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
          let closed = ?{ reason = #FullyFilled; at = env.now };
          sell_o := { sell_o with closed };
          orders := RBTree.insert(orders, Nat.compare, sell_id, sell_o);

          sell_lvl := Book.levelDelOrder(sell_lvl, sell_id);
          sell_book := Book.saveLevel(sell_book, sell_p, sell_lvl);

          var user = getUser(sell_o.owner);
          var subacc = Book.getSubaccount(user, sell_o.sub);
          subacc := Book.subaccDelSellLevel(subacc, sell_o);
          user := Book.saveSubaccount(user, sell_o.sub, subacc);
          user := saveUser(sell_o.owner, user);

          orders_by_expiry := Book.delExpiry(orders_by_expiry, sell_o.expires_at, sell_id);
          orders_by_expiry := Book.newExpiry(orders_by_expiry, sell_o.expires_at + env.ttl, sell_id);

          next_sell_o := true;
          continue timing;
        };
        if (buy_o.base.filled >= buy_o.base.initial) {
          let closed = ?{ reason = #FullyFilled; at = env.now };
          buy_o := { buy_o with closed };
          orders := RBTree.insert(orders, Nat.compare, buy_id, buy_o);

          buy_lvl := Book.levelDelOrder(buy_lvl, buy_id);
          buy_book := Book.saveLevel(buy_book, buy_p, buy_lvl);

          var user = getUser(buy_o.owner);
          var subacc = Book.getSubaccount(user, buy_o.sub);
          subacc := Book.subaccDelBuyLevel(subacc, buy_o);
          user := Book.saveSubaccount(user, buy_o.sub, subacc);
          user := saveUser(buy_o.owner, user);

          orders_by_expiry := Book.delExpiry(orders_by_expiry, buy_o.expires_at, buy_id);
          orders_by_expiry := Book.newExpiry(orders_by_expiry, buy_o.expires_at + env.ttl, buy_id);

          next_buy_o := true;
          continue timing;
        };
        let sell_unfilled = sell_o.base.initial - sell_o.base.filled;
        let sell_unfilled_q = sell_unfilled * sell_o.price / env.quote_power;
        let buy_unfilled = buy_o.base.initial - buy_o.base.filled;
        let buy_unfilled_q = buy_unfilled * buy_o.price / env.quote_power;
        if (sell_o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, sell_id, sell_o, sell_unfilled, sell_lvl, sell_unfilled_q);
        if (buy_o.expires_at < env.now) return await* refundClose(caller, sub, env, #Expired null, buy_id, buy_o, buy_unfilled, buy_lvl, buy_unfilled_q);
        if (sell_unfilled < env.min_base_amount or sell_unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, sell_id, sell_o, sell_unfilled, sell_lvl, sell_unfilled_q);
        if (buy_unfilled < env.min_base_amount or buy_unfilled_q < env.min_quote_amount) return await* refundClose(caller, sub, env, #AlmostFilled null, buy_id, buy_o, buy_unfilled, buy_lvl, buy_unfilled_q);

        let sell_maker = sell_id < buy_id;
        if (sell_o.owner == buy_o.owner /* and sell_o.sub == buy_o.sub  // do not check subaccount since we getUser() for both buyer & seller*/) {
          if (sell_maker) next_sell_o := true else next_buy_o := true;
          continue timing;
        };
        if (sell_o.price > buy_o.price) return Error.text("No matching needed");
        let maker_p = if (sell_maker) sell_o.price else buy_o.price;
        let (min_base, min_quote, min_side) = if (sell_unfilled < buy_unfilled) (sell_unfilled, sell_unfilled * maker_p / env.quote_power, false) else (buy_unfilled, buy_unfilled * maker_p / env.quote_power, true);
        if (min_quote < env.min_quote_amount) {
          if (min_side) next_buy_o := true else next_sell_o := true;
          continue timing;
        };
        var sell_u = getUser(sell_o.owner);
        var buy_u = getUser(buy_o.owner);
        var sell_sub = Book.getSubaccount(sell_u, sell_o.sub);
        var buy_sub = Book.getSubaccount(buy_u, buy_o.sub);
        sell_o := Book.lockOrder(sell_o, min_base);
        buy_o := Book.lockOrder(buy_o, min_base);

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
          env.maker_fee_numer * amt_q / env.fee_denom,
          env.taker_fee_numer * amt / env.fee_denom,
        ) else (
          env.taker_fee_numer * amt_q / env.fee_denom,
          env.maker_fee_numer * amt / env.fee_denom,
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
          sell_lvl := Book.getLevel(sell_book, sell_p);
          buy_lvl := Book.getLevel(buy_book, buy_p);
          sell_u := getUser(sell_o.owner);
          sell_sub := Book.getSubaccount(sell_u, sell_o.sub);
          buy_u := getUser(buy_o.owner);
          buy_sub := Book.getSubaccount(buy_u, buy_o.sub);
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
        saveMatch();

        let maker_reward = Nat.max(amt_q / env.min_quote_amount, 1);
        if (sell_maker) newReward(sell_o.owner, sell_s, maker_reward) else newReward(buy_o.owner, buy_s, maker_reward);
        newReward(caller, Subaccount.opt(sub), 1);

        let (block_id, phash) = ArchiveL.getPhash(blocks);
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
        let val = Book.valueTrade(trade_id, env.now, phash, sell_h, buy_h);
        newBlock(block_id, val);
        trade_id += 1;
        return #Ok block_id;
      };
      if (not next_sell_lvl and not next_buy_lvl) break pricing; // there must be one next to continue matching
    };
    Error.text("No matching available");
  };

  func newReward(owner : Principal, subaccount : ?Blob, rounds : Nat) {
    rewards := RBTree.insert(rewards, Nat.compare, reward_id, ({ rounds; account = { owner; subaccount } }, false));
    reward_id += 1;
  };

  func refundClose(caller : Principal, sub : Blob, env : B.Environment, reason : { #Expired : Null; #AlmostFilled : Null }, oid : Nat, _o : B.Order, unfilled : Nat, _lvl : B.Nats, unfilled_q : Nat) : async* B.RunRes {
    var o = _o;
    o := { o with closed = ?{ reason; at = env.now } };
    o := Book.lockOrder(o, unfilled);
    orders := RBTree.insert(orders, Nat.compare, oid, o);

    let account = { owner = o.owner; subaccount = Subaccount.opt(o.sub) };
    let unlock = { account; action = #Unlock };
    var lvl = _lvl;
    var user = getUser(o.owner);
    var subacc = Book.getSubaccount(user, o.sub);
    let (instruction) = if (o.is_buy) {
      buy_book := Book.saveLevel(buy_book, o.price, lvl);
      { unlock with token = env.quote_token_id; amount = unfilled_q };
    } else {
      sell_book := Book.saveLevel(sell_book, o.price, lvl);
      { unlock with token = env.base_token_id; amount = unfilled };
    };
    user := Book.saveSubaccount(user, o.sub, subacc);
    user := saveUser(o.owner, user);

    func unlockX<T>(t : T) : T {
      user := getUser(caller);
      subacc := Book.getSubaccount(user, sub);
      if (o.is_buy) {
        lvl := Book.getLevel(buy_book, o.price);
        buy_book := Book.saveLevel(buy_book, o.price, lvl);
      } else {
        lvl := Book.getLevel(sell_book, o.price);
        sell_book := Book.saveLevel(sell_book, o.price, lvl);
      };
      o := Book.unlockOrder(o, unfilled);
      o := { o with closed = null };
      orders := RBTree.insert(orders, Nat.compare, oid, o);
      user := Book.saveSubaccount(user, sub, subacc);
      user := saveUser(o.owner, user);
      t;
    };
    let user_bals = await env.vault.vault_locked_balances_of([instruction]);
    if (user_bals[0] < instruction.amount) return unlockX(Error.text("Insufficient balance"));

    let execute = switch (await env.vault.vault_execute([[instruction]])) {
      case (#Err err) return unlockX(#Err(#CloseFailed { order = oid; instruction_blocks = [[instruction]]; error = err }));
      case (#Ok ok) ok[0];
    };
    user := getUser(caller);
    subacc := Book.getSubaccount(user, sub);
    let val = if (o.is_buy) {
      lvl := Book.getLevel(buy_book, o.price);
      lvl := Book.levelDelOrder(lvl, oid);
      buy_book := Book.saveLevel(buy_book, o.price, lvl);
      let quote_locked = o.base.locked * o.price / env.quote_power;
      subacc := Book.subaccDelBuyLevel(subacc, o);
      [Book.valueClose(oid, "quote", quote_locked, 0, execute)];
    } else {
      lvl := Book.getLevel(sell_book, o.price);
      lvl := Book.levelDelOrder(lvl, oid);
      sell_book := Book.saveLevel(sell_book, o.price, lvl);
      subacc := Book.subaccDelSellLevel(subacc, o);
      [Book.valueClose(oid, "base", o.base.locked, 0, execute)];
    };
    orders_by_expiry := Book.delExpiry(orders_by_expiry, o.expires_at, oid);
    orders_by_expiry := Book.newExpiry(orders_by_expiry, o.expires_at + env.ttl, oid);

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    let proof = ?{ block = block_id; execute };
    let rzn = switch reason {
      case (#AlmostFilled _) #AlmostFilled proof;
      case (#Expired _) #Expired proof;
    };
    let closed = ?{ at = env.now; reason = rzn };
    o := { o with closed };
    orders := RBTree.insert(orders, Nat.compare, oid, o);
    user := Book.saveSubaccount(user, sub, subacc);
    user := saveUser(o.owner, user);
    newBlock(block_id, Book.valueCloses(null, env.now, val, phash));
    Error.text("No job available");
  };

  public shared query func rb_archive_min_block() : async ?Nat = async RBTree.minKey(blocks);
  public shared query func rb_archive_max_update_batch_size() : async ?Nat = async Value.metaNat(meta, A.MAX_UPDATE_BATCH_SIZE);

  public shared query func icrc3_get_blocks(gets : [ICRC3T.GetBlocksArg]) : async ICRC3T.GetBlocksResult = async ICRC3L.getBlocks(gets, blox, metadata);
};
