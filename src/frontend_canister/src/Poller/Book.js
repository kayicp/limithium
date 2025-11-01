import { idlFactory } from 'declarations/ckbtc_icp_book';
import Price from './Price';
import Order from './Order';
import Trade from './Trade';
import { wait, retry } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';

function equalMaps(map1, map2) {
  if (map1.size !== map2.size) return false;

  for (const [key, value] of map1) {
    const map2v = map2.get(key);
    if (!map2v) return false;
    if (map2v != value) return false;
  }
  return true;
}

// todo: maybe we only need "render", and draw html after calls
class Book {
  wallet = null;
  anon = null;
  id = null;

  orders = new Map(); // only best and user's orders
  trades = new Map();

  user_buys = [];
  user_sells = [];
  user_buy_lvls = new Map();
  user_sell_lvls = new Map();

  asks = [];
  bids = [];
  new_oids = [];

  recents = [];
  new_tids = [];
  
  constructor(book_id, wallet) {
    this.id = book_id;
    this.wallet = wallet;
    this.pubsub = wallet.pubsub;

    this.recents = Array.from({ length : 12 }, () => null);
    this.#init();
  }

  #render(err = null) {
    this.err = err;
    this.pubsub.emit('render');
  }

  async #init() {
    try {
      this.anon = await genActor(idlFactory, this.id);
    } catch (cause) {
      const err = new Error(`token meta:`, { cause }); 
      return this.#render(err);
    }
    this.#initAsks();
    this.#initBids();
    this.#initUserBuyLevels();
    this.#initUserSellLevels();
    this.#initUserBuyOrders();
    this.#initUserSellOrders();
    this.#initGetOrders();
    this.#initRecentTrades();
    this.#initGetTrades();
    this.#initUpdateOrders();
  }

  async #initAsks() {
    this.asks = Array.from({ length : 6 }, () => new Price(this.anon, false, this.orders, this.new_oids, this.trades, this.new_tids, this.wallet));

    let delay = 1000; // start with 1 second
    while (true) {
      try {
        has_change = false;
        const prices = await this.anon.book_ask_prices([], [this.asks.length]);
        for (let i = 0; i < this.asks.length; i++) {
          const price = prices[i] ?? 0n;
          if (price != this.asks[i].level) has_change = true;
          this.asks[i].changeLevel(price);
        }
        if (has_change) this.#render();
        delay = retry(has_change, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error('ask prices:', { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initBids() {
    this.bids = Array.from({ length : 6 }, () => new Price(this.anon, true, this.orders, this.new_oids, this.trades, this.new_tids, this.wallet));

    let delay = 1000; // start with 1 second
    while (true) {
      try {
        has_change = false;
        const prices = await this.anon.book_bid_prices([], [this.bids.length]);
        for (let i = 0; i < this.bids.length; i++) {
          const price = prices[i] ?? 0n;
          if (price != this.bids[i].level) has_change = true;
          this.bids[i].changeLevel(price);
        }
        if (has_change) this.#render();
        delay = retry(has_change, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error('bid prices:', { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initUserBuyLevels() {
    let delay = 1000;
    while (true) {
      const user_p = this.wallet.get().principal;
      const account = { owner : user_p, subaccount: [] };
      try {
        const user_buy_lvls = new Map(); 
        while (user_p != null) {
          let prev = [];
          const buy_lvls = await this.anon.book_buy_prices_by(account, prev, []);
          if (buy_lvls.length == 0) break;
          for (const [lvl, oid] of buy_lvls) {
            user_buy_lvls.set(lvl, oid);
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids, this.wallet));
              this.new_oids.push(oid);
            }
          }
        }
        const has_change = !equalMaps(this.user_buy_lvls, user_buy_lvls);
        this.user_buy_lvls = user_buy_lvls;
        if (has_change) this.#render();
        delay = retry(has_change, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error(`user's buy levels:`, { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initUserSellLevels() {
    let delay = 1000;
    while (true) {
      const user_p = this.wallet.get().principal;
      const account = { owner : user_p, subaccount: [] };
      try {
        const user_sell_lvls = new Map(); 
        while (user_p != null) {
          let prev = [];
          const sell_lvls = await this.anon.book_sell_prices_by(account, prev, []);
          if (sell_lvls.length == 0) break;
          for (const [lvl, oid] of sell_lvls) {
            user_sell_lvls.set(lvl, oid);
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids, this.wallet));
              this.new_oids.push(oid);
            }
          }
        }
        const has_change = !equalMaps(this.user_sell_lvls, user_sell_lvls);
        delay = retry(has_change, delay);
        this.user_sell_lvls = user_sell_lvls;
        if (has_change) this.#render();
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("user's sell levels", { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initUserBuyOrders() {
    let delay = 1000;
    while (true) {
      const user_p = this.wallet.get().principal;
      const account = { owner : user_p, subaccount: [] };
      try { // todo: this should be on a separate job
        let has_new = false;
        while (user_p != null) {
          const prev = this.user_buys.length > 0? [this.user_buys[this.user_buys.length - 1]] : [];
          const buys = await this.anon.book_buy_orders_by(account, prev, []);
          if (buys.length == 0) break;
          has_new = true;
          for (const oid of buys) {
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids, this.wallet));
              this.new_oids.push(oid);
              this.user_buys.push(oid);
            } else break;
          }
        }
        delay = retry(has_new, delay);
        if (has_new) this.#render();
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("user's buys", { cause });
        this.#render(err);
      }
      await wait(delay);
    };

  }

  async #initUserSellOrders() {
    let delay = 1000;
    while (true){
      const user_p = this.wallet.get().principal;
      const account = { owner : user_p, subaccount: [] };
      try { // todo: this should be on a separate job
        let has_new = false;
        while (user_p != null) {
          const prev = this.user_sells.length > 0? [this.user_sells[this.user_sells.length - 1]] : [];
          const sells = await this.anon.book_sell_orders_by(account, prev, []);
          if (sells.length == 0) break;
          has_new = true;
          for (const oid of sells) {
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids, this.wallet));
              this.new_oids.push(oid);
              this.user_sells.push(oid);
            }
          }
        }
        delay = retry(has_new, delay);
        if (has_new) this.#render();
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("user's sells", { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initGetOrders() {
    let delay = 1000;
    while (true) {
      try {
        while (this.new_oids.length > 0) {
          const [
            sides, owners, blocks, execs, prices, expiries, initials, subaccs, createdats
          ] = await Promise.all([
            this.anon.book_order_sides_of(this.new_oids),
            this.anon.book_order_owners_of(this.new_oids),
            this.anon.book_order_blocks_of(this.new_oids),
            this.anon.book_order_executions_of(this.new_oids),
            this.anon.book_order_prices_of(this.new_oids),
            this.anon.book_order_expiry_timestamps_of(this.new_oids),
            this.anon.book_order_initial_amounts_of(this.new_oids),
            this.anon.book_order_subaccounts_of(this.new_oids),
            this.anon.book_order_created_timestamps_of(this.new_oids),
          ]);
          
          for (let i = 0; i < sides.length; i++) {
            const [
              side, owner, block, exec, price, expiry, initial, subacc, createdat
            ] = [
              sides[i], owners[i], blocks[i], execs[i], prices[i], expiries[i], initials[i], subaccs[i], createdats[i]
            ];
            const oid = this.new_oids[i];
            const o = this.orders.get(oid);
            o.is_buy = side[0];
            o.owner = owner[0];
            o.block = block[0];
            o.exec = exec[0];
            o.price = price[0];
            o.expires_at = expiry[0];
            o.base.initial = initial[0];
            o.subacc = subacc[0];
            o.created_at = createdat[0];
          };
          this.new_oids.splice(0, sides.length);
        };
        delay = retry(true, delay);
        this.#render();
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("get orders", { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }

  async #initRecentTrades() {
    let delay = 1000;
    while (true) {
      try {
        const tids = await this.anon.book_trade_ids([], [this.recents.length]);
        let has_change = false;
        for (let i = 0; i < this.recents.length; i++) {
          const tid = tids[i];
          if (tid != this.recents[i]) has_change = true;
          this.recents[i] = tid;

          const t = this.trades.get(tid);
          if (!t) {
            this.trades.set(tid, new Trade(tid));
            this.new_tids.push(tid);
          };
        }
        delay = retry(has_change, delay);
        if (has_change) this.#render();
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("recent trades", { cause });
        this.#render(err);
      }
      await wait(delay);
    };
  }

  async #initGetTrades() {
    let delay = 1000;
    while (true) {
      try {
        while (this.new_tids.length > 0) {
          const [
            sell_ids, sell_bases, sell_fee_quotes, sell_execs, sell_fee_execs,
            buy_ids, buy_quotes, buy_fee_bases, buy_execs, buy_fee_execs,
            timestamps, blocks
          ] = await Promise.all([
            this.anon.book_trade_sell_ids_of(this.new_tids),
            this.anon.book_trade_sell_bases_of(this.new_tids),
            this.anon.book_trade_sell_fee_quotes_of(this.new_tids),
            this.anon.book_trade_sell_executions_of(this.new_tids),
            this.anon.book_trade_sell_fee_executions_of(this.new_tids),
            this.anon.book_trade_buy_ids_of(this.new_tids),
            this.anon.book_trade_buy_quotes_of(this.new_tids),
            this.anon.book_trade_buy_fee_bases_of(this.new_tids),
            this.anon.book_trade_buy_executions_of(this.new_tids),
            this.anon.book_trade_buy_fee_executions_of(this.new_tids),
            this.anon.book_trade_timestamps_of(this.new_tids),
            this.anon.book_trade_blocks_of(this.new_tids),
          ]);
  
          for (let i = 0; i < sell_ids.length; i++) {
            const [
              sell_id, sell_base, sell_fee_quote, sell_exec, sell_fee_exec,
              buy_id, buy_quote, buy_fee_base, buy_exec, buy_fee_exec,
              timestamp, block
            ] = [
              sell_ids[i], sell_bases[i], sell_fee_quotes[i], sell_execs[i], sell_fee_execs[i],
              buy_ids[i], buy_quotes[i], buy_fee_bases[i], buy_execs[i], buy_fee_execs[i],
              timestamps[i], blocks[i]
            ];
            const tid = this.new_tids[i];
            const t = this.trades.get(tid);
            t.sell_id = sell_id[0];
            t.sell_base = sell_base[0];
            t.sell_fee_quote = sell_fee_quote[0];
            t.sell_exec = sell_exec[0];
            t.sell_fee_exec = sell_fee_exec[0];
            t.buy_id = buy_id[0];
            t.buy_quote = buy_quote[0];
            t.buy_fee_base = buy_fee_base[0];
            t.buy_exec = buy_exec[0];
            t.buy_fee_exec = buy_fee_exec[0];
            t.created_at = timestamp[0];
            t.block = block[0];
          }
          this.new_tids.splice(0, sell_ids.length);
        }
        delay = retry(true, delay);
        this.#render();  
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("get trades", { cause });
        this.#render(err);
      }
      await wait(delay);
    };
  }

  async #initUpdateOrders() {
    let delay = 1000;
    while (true) {
      try {
        const oids = [...this.orders.keys()];
        let has_change = false;
        while (oids.length > 0) {
          const [closedats, closedreasons, lockeds, filleds] = await Promise.all([
            this.anon.book_order_closed_timestamps_of(oids),
            this.anon.book_order_closed_reasons_of(oids),
            this.anon.book_order_locked_amounts_of(oids),
            this.anon.book_order_filled_amounts_of(oids),
          ]);
  
          for (let i = 0; i < closedats.length; i++) {
            const oid = oids[i];
            const o = this.orders.get(oid);
            const [closedat, closedreason, locked, filled] = [closedats[i], closedreasons[i], lockeds[i], filleds[i]];
            if (o.closed_at != closedat[0]) has_change = true;
            o.closed_at = closedat[0];

            if (o.closed_reason != closedreason[0]) has_change = true;
            o.closed_reason = closedreason[0];
            
            if (o.base.locked != locked[0]) has_change = true;
            o.base.locked = locked[0];

            if (o.base.filled != filled[0]) has_change = true;
            o.base.filled = filled[0];
          }
          oids.splice(0, closedats.length);
        }
        if (has_change) this.#render();
        delay = retry(has_change, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error("update orders", { cause });
        this.#render(err);
      }
      await wait(delay);
    }
  }
}

export default Book;

// todo: get user's orders