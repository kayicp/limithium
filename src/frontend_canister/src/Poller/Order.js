import Amount from '../Types/Amount';

class Order {
	id = 0n;
	book_anon = null;

	base = new Amount();
	is_buy = null;
	owner = null;
	block = null;
	exec = null;
	price = 0n;
	closed_at = null;
	closed_reason = null;
	expires_at = 0n;
	subacc = null;
	created_at = 0n;
	tids = [];

	constructor(id, book_anon, trades, new_tids) {
		this.id = id;
		this.book_anon = book_anon;

		setInterval(() => {
			try {
				while (true) {
					const prev = this.tids.length > 0? [this.tids[this.tids.length - 1]] : [];
					const tids = book_anon.book_order_trades_of(id, prev, []);
					if (trades.length == 0) break;
					for (const tid of tids) {
						this.tids.push(tid);
						const t = trades.get(tid);
						if (!t) new_tids.push(tid);
					}
				}
			} catch (cause) {
				console.error('trades', cause)
			}
		}, 1000);
	}

}

export default Order;