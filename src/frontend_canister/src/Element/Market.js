import { html } from 'lit-html';
import { nano2date } from '../../../util/js/bigint';

export default class Market {
	static PATH = '/market';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button 
			class="inline-flex items-center px-2 py-1 text-xs rounded-md font-medium bg-slate-800 hover:bg-slate-700 text-slate-100 ring-1 ring-slate-700"
			@click=${(e) => {
				e.preventDefault();
				if (window.location.pathname.startsWith(Market.PATH)) return;
				this.#render();
				history.pushState({}, '', Market.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Market</button>
		`;
		this.vault.pubsub.on('render', () => this.#render());
	}

	priceInputHandler(e, book){
    const el = e.target;
    const form = el.closest('.order-form');
    const baseEl = form.querySelector('input[name="base"]');
    const quoteEl = form.querySelector('input[name="quote"]');
    const priceVal = parseFloat(el.value || '0');
    const baseVal = parseFloat(baseEl.value || '0');
    const quoteVal = parseFloat(quoteEl.value || '0');

    book.form.price = el.value;
    // if base present -> update quote, else if quote present -> update base
    if (!Number.isNaN(baseVal) && baseEl.value !== '') {
      quoteEl.value = baseVal * priceVal;
      book.form.quote = quoteEl.value;
    } else if (!Number.isNaN(quoteVal) && quoteEl.value !== '') {
      const b = priceVal === 0 ? 0 : (quoteVal / priceVal);
      baseEl.value = b;
      book.form.base = baseEl.value;
    }
		this.vault.pubsub.emit('render');
  };

  baseInputHandler(e, book){
    const el = e.target;
    const form = el.closest('.order-form');
    const priceEl = form.querySelector('input[name="price"]');
    const quoteEl = form.querySelector('input[name="quote"]');
    const priceVal = parseFloat(priceEl.value || book.form.price || '0');
    const baseVal = parseFloat(el.value || '0');
    book.form.base = el.value;
    if (!Number.isNaN(baseVal)) {
      quoteEl.value = baseVal * (priceVal || 0);
      book.form.quote = quoteEl.value;
    } else {
      quoteEl.value = '';
      book.form.quote = '';
    }
		this.vault.pubsub.emit('render');
  };

  quoteInputHandler(e, book){
    const el = e.target;
    const form = el.closest('.order-form');
    const priceEl = form.querySelector('input[name="price"]');
    const baseEl = form.querySelector('input[name="base"]');
    const priceVal = parseFloat(priceEl.value || book.form.price || '0');
    const quoteVal = parseFloat(el.value || '0');
    book.form.quote = el.value;
    if (!Number.isNaN(quoteVal) && priceVal !== 0) {
      baseEl.value = quoteVal / priceVal;
      book.form.base = baseEl.value;
    } else {
      baseEl.value = '';
      book.form.base = '';
    }
		this.vault.pubsub.emit('render');
  };

	#render() {
		const pair_options = [];
		const pair_keys = [];
		for (const [b_id, b] of this.vault.books) {
			if (!b.base_token || !b.quote_token) continue;
			const base_t = this.vault.tokens.get(b.base_token.toText());
			const quote_t = this.vault.tokens.get(b.quote_token.toText());
			if (!base_t?.ext?.symbol || !quote_t?.ext?.symbol) continue;
			const pair = `${base_t.ext.symbol}/${quote_t.ext.symbol}`;
			if (!this.vault.selected_book && pair.includes('ckBTC')) this.vault.selected_book = b_id;
			pair_keys.push(pair);
			pair_options.push(html`<option class="bg-slate-800 text-slate-100 text-xs" value="${b_id}" ?selected=${b_id == this.vault.selected_book}>${pair}</option>`);
		}
		if (pair_keys.length == 0) {
			this.page = html`<div class="text-xs text-slate-400">Loading...</div>`;
		} else {
			const book = this.vault.books.get(this.vault.selected_book);
			const base_t = this.vault.tokens.get(book.base_token.toText());
			const quote_t = this.vault.tokens.get(book.quote_token.toText());
			let last_trade_price = null;
			const live_trades = book.recents.map(trade_id => {
				if (!trade_id) return html`<div class="text-xs text-slate-500">—</div>`;
				const t = book.trades.get(trade_id);
				if (!t) return html`<div class="text-xs text-slate-500">—</div>`;
				if (t.sell_id == null) return html`<div class="text-xs text-slate-500">—</div>`;
				const is_buy = t.sell_id < t.buy_id;
				const amount = base_t.ext.clean(t.sell_base);
				const price = quote_t.ext.clean(Number(t.buy_quote) / Number(t.sell_base));
				if (!last_trade_price) last_trade_price = price;
				const timestamp = nano2date(t.created_at);
				return html`
<div class="flex justify-between items-center text-xs">
	<div class="${is_buy ? 'text-emerald-400' : 'text-rose-400'} font-medium">${is_buy ? 'BUY' : 'SELL'}</div>
	<div class="text-slate-200">${amount}</div>
	<div class="text-slate-400">${price}</div>
	<div class="text-slate-500 ml-2">${timestamp.toLocaleTimeString()}</div>
</div>`;
			});
			const asks = book.asks.map(price => {
				if (price.level == 0n) return html`<div class="text-xs text-slate-500">—</div>`;
				const price_lvl = quote_t.ext.clean(price.level);
				const amount = base_t.ext.clean(price.base.initial - price.base.filled - price.base.locked);
				return html`
<div class="flex justify-between items-center text-xs text-slate-300">
	<div class="text-slate-400">${price_lvl}</div>
	<div class="font-medium text-rose-400">${amount}</div>
</div>`;
			});
			const bids = book.bids.map(price => {
				if (price.level == 0n) return html`<div class="text-xs text-slate-500">—</div>`;
				const price_lvl = quote_t.ext.clean(price.level);
				const amount = base_t.ext.clean(price.base.initial - price.base.filled - price.base.locked);
				return html`
<div class="flex justify-between items-center text-xs text-slate-300">
	<div class="font-medium text-emerald-400">${amount}</div>
	<div class="text-slate-400">${price_lvl}</div>
</div>`;
			});

			let opened_orders = html`<div class="text-slate-400">Connect your wallet to see your orders</div>`;
			if (this.vault.wallet.get().principal) {
				const my_buys = book.user_buys.length > 0? book.user_buys.map(order_id => book.renderOpen(order_id, base_t, quote_t)) : html`<div class="text-xs text-slate-400">No buy orders</div>`;
				const my_sells = book.user_sells.length > 0? book.user_sells.map(order_id => book.renderOpen(order_id, base_t, quote_t)) : html`<div class="text-xs text-slate-500">No sell orders</div>`;
				opened_orders = html`
				<div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
					<div>
						<div class="text-emerald-300 text-xs font-medium mb-2">Buys</div>
						<div class="flex flex-col gap-2">${my_buys}</div>
					</div>
		
					<div>
						<div class="text-rose-300 text-xs font-medium mb-2">Sells</div>
						<div class="flex flex-col gap-2">${my_sells}</div>
					</div>
				</div>
			`;
			};
			
			this.page = html`
				<div class="w-full max-w-6xl mx-auto">
					<!-- pair options -->
					<div class="mb-3">
						<select
							class="w-full sm:w-64 bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700"
							@change=${(e) => { 
								this.vault.selected_book = e.target.value;
								this.vault.pubsub.emit('render');
							}}>
							${pair_options}
						</select>
					</div>
					<!-- main grid: left live trades | middle orderbook | right order form -->
					<div class="grid grid-cols-1 md:grid-cols-12 gap-3">
						<div class="md:col-span-3 bg-slate-800/30 ring-1 ring-slate-700 rounded-md p-2 text-xs min-h-0 min-w-0">
							<div class="font-medium text-slate-300 mb-2">Live Trades</div>
							<div class="flex flex-col gap-1 max-h-72 overflow-y-auto pr-1">${live_trades}</div>
						</div>
						<div class="md:col-span-6 bg-slate-800/30 ring-1 ring-slate-700 rounded-md p-2 text-xs min-h-0 min-w-0">
							<div class="grid grid-cols-1 gap-2">
								<div class="flex flex-col gap-1">${asks}</div>
	
								<div class="flex items-center justify-center my-2">
									<div class="text-sm font-semibold text-slate-100 px-3 py-1 bg-slate-800 rounded-md ring-1 ring-slate-700">
										${last_trade_price}
									</div>
								</div>
	
								<div class="flex flex-col gap-1">${bids}</div>
							</div>
						</div>

						<!-- RIGHT: order form (col-span 3) -->
						<div class="md:col-span-3 bg-slate-800/30 ring-1 ring-slate-700 rounded-md p-3 text-xs min-h-0 min-w-0">
							<div class="font-medium text-slate-300 mb-2">Limit Order</div>

							<div class="order-form">
								<!-- side selector -->
								<div class="mb-2">
									<label class="block text-xs text-slate-400 mb-1">Side</label>
									<select
										class="w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700"
										.value=${book.form.is_buy? 'buy' : 'sell'}
										@change=${(e) => { 
											book.form.is_buy = e.target.value == 'buy'; 
											this.vault.pubsub.emit('render');
										}}
									>
										<option value="buy" ?selected=${book.form.is_buy == true}>Buy</option>
										<option value="sell" ?selected=${book.form.is_buy == false}>Sell</option>
									</select>
								</div>
								<!-- price -->
								<div class="mb-2">
									<label class="block text-xs text-slate-400 mb-1">Price (${quote_t.ext.symbol})</label>
									<input
										name="price"
										class="w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700 placeholder:text-slate-500"
										type="text"
										inputmode="decimal"
										.value=${book.form.price ?? String(last_trade_price || 0)}
										@input=${(e) => this.priceInputHandler(e, book)}
									>
								</div>
								<!-- base amount -->
								<div class="mb-2">
									<label class="block text-xs text-slate-400 mb-1">Amount (${base_t.ext.symbol})</label>
									<input
										name="base"
										class="w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700 placeholder:text-slate-500"
										type="text"
										inputmode="decimal"
										.value=${book.form.base}
										@input=${(e) => this.baseInputHandler(e, book)}
									>
								</div>
								<!-- quote amount -->
								<div class="mb-3">
									<label class="block text-xs text-slate-400 mb-1">Total (${quote_t.ext.symbol})</label>
									<input
										name="quote"
										class="w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700 placeholder:text-slate-500"
										type="text"
										inputmode="decimal"
										.value=${book.form.quote}
										@input=${(e) => this.quoteInputHandler(e, book)}
									>
								</div>
								<!-- action -->
								<div class="flex gap-2">
									<button
										class="flex-1 px-3 py-1 text-sm rounded-md font-semibold ${book.form.is_buy? 'bg-emerald-600 hover:bg-emerald-500' : 'bg-rose-600 hover:bg-rose-500'} text-white disabled:opacity-60"
										?disabled=${book.form.busy}
										@click=${() => book.openOrder(base_t, quote_t)}
									>${book.form.is_buy ? 'Buy' : 'Sell'}</button>
								</div>
							</div>
						</div>
					</div>
					${opened_orders}
				</div>
			`;
		}
	}


}