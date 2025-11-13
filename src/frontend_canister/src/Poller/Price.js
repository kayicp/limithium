import Order from './Order';
import Amount from '../Types/Amount';
import { wait, retry } from '../../../util/js/wait';

function setsEqual(set1, set2) {
  if (set1.size !== set2.size) return false;
  for (const value of set1) {
    if (!set2.has(value)) return false;
  }
  return true;
}

class Price {
	curr_level = 0n;
	next_level = 0n;

	oids = new Set();
	base = new Amount();

	err = null;

	constructor(book_anon, is_buy, orders, new_oids, trades, new_tids, wallet) {
		this.book_anon = book_anon;
		this.orders = orders;
		this.new_oids = new_oids;
		this.trades = trades;
		this.new_tids = new_tids;
		this.wallet = wallet;
		this.pubsub = wallet.notif.pubsub;

		this.#init(is_buy);
	}

	#render(err = null) {
		this.err = err;
		if (err) console.error(err)
		this.pubsub.emit('render');
	}

	async #init(is_buy) {
		const orders_at = is_buy? this.book_anon.book_bids_at : this.book_anon.book_asks_at;
		let delay = 1000;
		while (true) {
			const level = this.next_level || this.curr_level;
			if (level > 0n) {
				let prev = [];
				const _oids = new Set();
				const _base = new Amount();
				try {
					getting: while (true) {
						const oids = await orders_at(level, prev, []);
						if (oids.length == 0) break getting;
						prev = [oids[oids.length - 1]];
						for (const oid of oids) {
							_oids.add(oid);
							const o = this.orders.get(oid);
							if (!o) {
								this.orders.set(oid, new Order(oid, this.book_anon, this.trades, this.new_tids, this.wallet));
								this.new_oids.push(oid);
							} else {
								_base.add(o.base);
							}
						}
					}
					const has_change = !setsEqual(this.oids, _oids);
					delay = retry(has_change, delay);
					this.oids = _oids;
					this.base = _base;
					this.curr_level = level;
					if (has_change) this.#render();
				} catch (cause) {
					delay = retry(false, delay);
					const err = new Error(`price oids:`, { cause });
        	this.#render(err);
				}
			} else {
				delay = retry(true, delay);
				this.oids = new Set();
				this.base = new Amount();
				this.curr_level = 0n;
				this.next_level = 0n;
			};
			if (await wait(delay, this.pubsub) == 'refresh') delay = 1000;
		}
	}

	changeLevel(lvl = 0n) {
		this.next_level = lvl;
		if (lvl == 0n) this.curr_level = lvl;
	}
}

export default Price;