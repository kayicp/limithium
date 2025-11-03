import { html } from 'lit-html';

export default class Market {
	static PATH = '/market';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button @click=${(e) => {
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
		const pair_keys = []; 
		const pair_options = [];
		for (const [b_id, b] of this.vault.books) {
			if (!b.base_token || !b.quote_token) continue;
			const base_t = this.vault.tokens.get(b.base_token.toText());
			const quote_t = this.vault.tokens.get(b.quote_token.toText());
			if (!base_t?.ext?.symbol || !quote_t?.ext?.symbol) continue;
			const pair = `${base_t.ext.symbol}/${quote_t.ext.symbol}`;
			if (!this.vault.selected_book && pair.includes('ckBTC')) this.vault.selected_book = b_id;
			pair_keys.push(pair);
			pair_options.push(html`<option value="${b_id}" ?selected=${b_id == this.vault.selected_book}>${pair}</option>`);
		}
		if (pair_keys.length == 0) return html`<div>Loading...</div>`; 

		this.page = html`
<div>
	<select>${pair_options}</select>
	
</div>`
	}
}