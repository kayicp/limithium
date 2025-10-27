import { createActor } from 'declarations/ckbtc_icp_book';
import Price from './Price';
import Order from './Order';

class Book {
  wallet = null;
  anon = null;

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
  
  constructor(p, wallet) {
    this.wallet = wallet;
    this.anon = createActor(p);
    
    this.asks = Array.from({ length : 6 }, () => new Price(p, false, this.orders, this.new_oids, this.trades, this.new_tids));
    this.bids = Array.from({ length : 6 }, () => new Price(p, true, this.orders, this.new_oids, this.trades, this.new_tids));
    this.recents = Array.from({ length : 12 }, () => null);

    // todo: dont use setinterval, but use wait after job done
    setInterval(async () => {
      try {
        const [ask_prices, bid_prices] = await Promise.all([
          this.anon.book_ask_prices([], [this.asks.length]),
          this.anon.book_bid_prices([], [this.bids.length])
        ])
        for (let i = 0; i < this.asks.length; i++) {
          this.asks[i].changeLevel(ask_prices[i] ?? 0n);
        }
        for (let i = 0; i < this.bids.length; i++) {
          this.bids[i].changeLevel(bid_prices[i] ?? 0n);
        }
      } catch (cause) {
        console.error('prices:', cause);
      }

      const p = wallet.get().principal;
      const account = { owner : p, subaccount: [] };

      try {
        const user_buy_lvls = new Map(); 
        while (p != null) {
          let prev = [];
          const buy_lvls = await this.anon.book_buy_prices_by(prev, []);
          if (buy_lvls.length == 0) break;
          for (const [lvl, oid] of buy_lvls) {
            user_buy_lvls.set(lvl, oid);
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids));
              this.new_oids.push(oid);
            }
          }
        }
        this.user_buy_lvls = user_buy_lvls;
      } catch (cause) {
        console.error("user's buy levels", cause)
      }

      try {
        const user_sell_lvls = new Map(); 
        while (p != null) {
          let prev = [];
          const sell_lvls = await this.anon.book_sell_prices_by(prev, []);
          if (sell_lvls.length == 0) break;
          for (const [lvl, oid] of sell_lvls) {
            user_sell_lvls.set(lvl, oid);
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids));
              this.new_oids.push(oid);
            }
          }
        }
        this.user_sell_lvls = user_sell_lvls;
      } catch (cause) {
        console.error("user's sell levels", cause)
      }

      try { // todo: this should be on a separate job
        while (p != null) {
          const prev = this.user_buys.length > 0? [this.user_buys[this.user_buys.length - 1]] : [];
          const buys = await this.anon.book_buy_orders_by(account, prev, []);
          if (buys.length == 0) break;
          for (const oid of buys) {
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids));
              this.new_oids.push(oid);
              this.user_buys.push(oid);
            } else break;
          }
        }
      } catch (cause) {
        console.error("user's buys", cause)
      }

      try { // todo: this should be on a separate job
        while (p != null) {
          const prev = this.user_sells.length > 0? [this.user_sells[this.user_sells.length - 1]] : [];
          const sells = await this.anon.book_sell_orders_by(account, prev, []);
          if (sells.length == 0) break;
          for (const oid of sells) {
            const o = this.orders.get(oid);
            if (!o) {
              this.orders.set(oid, new Order(oid, this.anon, this.trades, this.new_tids));
              this.new_oids.push(oid);
              this.user_sells.push(oid);
            }
          }
        }
      } catch (cause) {
        console.error("user's sells", cause)
      }

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
						o.is_buy = side.length > 0 ? side[0] : null;
            o.owner = owner.length > 0 ? owner[0] : null;
            o.block = block.length > 0 ? block[0] : null;
            o.exec = exec.length > 0 ? exec[0] : null;
            o.price = price.length > 0 ? price[0] : null;
            o.expires_at = expiry.length > 0 ? expiry[0] : null;
            o.base.initial = initial.length > 0 ? initial[0] : 0;
            o.subacc = subacc.length > 0 ? subacc[0] : null;
            o.created_at = createdat.length > 0 ? createdat[0] : null;
					};
					this.new_oids.splice(0, sides.length);
				};
			} catch (cause) {
				console.error('new oids', cause);
			}

      try {
        const tids = await this.anon.book_trade_ids([], [this.recents.length]);
        for (const tid of tids) {
          const t = this.trades.get(tid);
          if (!t) {
            this.trades.set(tid, new Trade(tid));
            this.new_tids.push(tid);
          } else break;
        };
      } catch (cause) {
        console.error('recent trades', cause);
      }

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
            t.sell_id = sell_id.length > 0 ? sell_id[0] : null;
            t.sell_base = sell_base.length > 0 ? sell_base[0] : null;
            t.sell_fee_quote = sell_fee_quote.length > 0 ? sell_fee_quote[0] : null;
            t.sell_exec = sell_exec.length > 0 ? sell_exec[0] : null;
            t.sell_fee_exec = sell_fee_exec.length > 0 ? sell_fee_exec[0] : null;
            t.buy_id = buy_id.length > 0 ? buy_id[0] : null;
            t.buy_quote = buy_quote.length > 0 ? buy_quote[0] : null;
            t.buy_fee_base = buy_fee_base.length > 0 ? buy_fee_base[0] : null;
            t.buy_exec = buy_exec.length > 0 ? buy_exec[0] : null;
            t.buy_fee_exec = buy_fee_exec.length > 0 ? buy_fee_exec[0] : null;
            t.created_at = timestamp.length > 0? timestamp[0] : null;
            t.block = block.length > 0? block[0] : null;
          }
          this.new_tids.splice(0, sell_ids.length);
        }
      } catch (cause) {
        console.error('new tids', cause);
      }

      try {
        const oids = [...this.orders.keys()];
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
            o.closed_at = closedat.length > 0? closedat[0] : null;
            o.closed_reason = closedreason.length > 0? closedreason[0] : null;
            o.base.locked = locked.length > 0? locked[0] : null;
            o.base.filled = filled.length > 0? filled[0] : null;
          }
          oids.splice(0, closedats.length);
        }
      } catch (cause) {
        console.error('order updates', cause);
      }
    }, 1000);
  }
}

export default Book;

// todo: get user's orders