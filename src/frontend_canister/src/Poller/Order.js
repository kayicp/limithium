import Amount from '../Types/Amount';
import { wait, retry } from '../../../util/js/wait';

class Order {
	base = new Amount();
	is_buy = null;
	owner = null;
	block = null;
	exec = null;
	price = null;
	closed_at = null;
	closed_reason = null;
	expires_at = null;
	subacc = null;
	created_at = null;
	tids = [];

	err = null;
	close_busy = false;

	constructor(id, book_anon, trades, new_tids, wallet) {
		this.id = id;
		this.book_anon = book_anon;
		this.trades = trades;
		this.new_tids = new_tids;
		this.wallet = wallet;
		this.pubsub = wallet.pubsub;
		this.#init();
	}

	#render(err = null) {
		this.err = err;
		if (err) console.error(err)
		this.pubsub.emit('render');
	}

	async #init() {
		let delay = 1000;
		while (true) {
			try {
				let has_change = false;
				while (true) {
					const prev = this.tids.length > 0? [this.tids[this.tids.length - 1]] : [];
					const tids = await this.book_anon.book_order_trades_of(this.id, prev, []);
					if (this.trades.length == 0) break;
					has_change = true;
					for (const tid of tids) {
						this.tids.push(tid);
						const t = this.trades.get(tid);
						if (!t) this.new_tids.push(tid);
					}
				}
				delay = retry(has_change, delay);
				if (has_change) this.#render();
			} catch (cause) {
				delay = retry(false, delay)
				const err = new Error('order trades:', { cause });
				this.#render(err);
			}
			await wait(delay);
		}
	}

}

export default Order;