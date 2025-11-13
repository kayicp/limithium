import Amount from '../Types/Amount';
import { wait, retry } from '../../../util/js/wait';
import { nano2date } from '../../../util/js/bigint';
import { html } from 'lit-html';

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
	show_trades = false;
	trades_ui = [];

	constructor(id, book_anon, trades, new_tids, wallet) {
		this.id = id;
		this.book_anon = book_anon;
		this.trades = trades;
		this.new_tids = new_tids;
		this.wallet = wallet;
		this.pubsub = wallet.notif.pubsub;
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
			if (await wait(delay, this.pubsub) == 'refresh') delay = 1000;
		}
	}

	showTrades() {
		this.show_trades = !this.show_trades;
		this.#render();
	}

	drawTrades(base_t, quote_t) {
		return this.tids.map(t_id => {
			const t = this.trades.get(t_id);
			let role = '—';
			if (t?.sell_id != null || t?.buy_id != null) {
				if (this.id == t.sell_id) {
					role = t.sell_id < t.buy_id? 'Maker' : 'Taker';
				} else if (this.id == t.buy_id) {
					role = t.buy_id < t.sell_id? 'Maker' : 'Taker';
				}
			};
			const side = this.is_buy == null? '—' : this.is_buy? 'Buy' : 'Sell';
			const t_base = t?.sell_base? base_t.ext.clean(t.sell_base) : '—';
			const t_quote = t?.buy_quote? quote_t.ext.clean(t.buy_quote) : '—';
			const t_price = t_base == '—' && t_quote == '—'? '—' : quote_t.ext.price(t.buy_quote, t.sell_base);
			let fee_symbol = '—';
			let fee_amt = '—';
			if (side == 'Buy' && t?.buy_fee_base) {
				fee_symbol = base_t.ext.symbol;
				fee_amt = base_t.ext.clean(t.buy_fee_base);
			} else if (side == 'Sell' && t?.sell_fee_quote) {
				fee_symbol = quote_t.ext.symbol;
				fee_amt = quote_t.ext.clean(t.sell_fee_quote);
			}
			const t_at = t?.created_at? nano2date(t.created_at).toLocaleTimeString() : '—';
			return html`
			<div class="flex items-center justify-between gap-2 p-2 bg-slate-800/20 rounded-md text-xs">
				<div class="min-w-0">
					<div class="flex items-center gap-2">
						<div class="text-slate-300 font-medium truncate">${t_base} ${base_t.ext.symbol}</div>
						<div class="text-slate-400 text-xs">${t_price}</div>
						<div class="text-slate-400 text-xs">${t_at}</div>
					</div>
					<div class="mt-1 text-slate-400 text-[11px]">
						<span class="mr-2">Role: <span class="text-slate-200">${role}</span></span>
						<span class="mr-2">Fee: <span class="text-slate-200">${fee_amt} ${fee_symbol}</span></span>
						<span>Quote: <span class="text-slate-200">${t_quote}</span></span>
					</div>
				</div>
			</div>`
		});
	}

}

export default Order;