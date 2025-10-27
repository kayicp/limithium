import Order from './Order';
import Base from '../Types/Base';

class Price {
	level = 0;

	oids = new Set();
	base = new Base();

	constructor(book_anon, is_buy, orders, new_oids, trades, new_tids) {
		const orders_at = is_buy? book_anon.book_bids_at : book_anon.book_asks_at;

		setInterval(async () => {
			if (this.level == 0) return;
			let prev = [];
			const _oids = new Set();
			const _base = new Base();
			try {
				getting: while (true) {
					const oids = await orders_at(this.level, prev, []);
					if (oids.length == 0) break getting;
					prev = [oids[oids.length - 1]];
					for (const oid of oids) {
						_oids.add(oid);
						const o = orders.get(oid);
						if (!o) {
							orders.set(oid, new Order(oid, book_anon, trades, new_tids));
							new_oids.push(oid);
						} else {
							_base.add(o.base);
						}
					}
				}
				this.oids = _oids;
				this.base = _base;
				if (this.oids.size == 0) this.level = 0;
			} catch (cause) {
				console.error('price oids', cause);
			}
		}, 1000);
	}

	changeLevel(lvl = 0n) {
		this.level = lvl;
		this.oids = new Set();
		this.base = new Base();
	}
}

export default Price;