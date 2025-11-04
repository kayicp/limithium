import { html } from 'lit-html';

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
			this.page = html`
				<div class="w-full max-w-sm">
					<label class="block text-xs text-slate-400 mb-1">Market</label>
					<select
						class="w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700"
						@change=${(e) => { this.vault.selected_book = e.target.value; }}>
						${pair_options}
					</select>
				</div>`;
		}
	}
}