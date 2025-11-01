import { html } from 'lit-html';

export default class Market {
	static PATH = '/market';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				this.#render();
				history.pushState({}, '', Market.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Market</button>
		`;

		this.page = null;
	}

	#render() {
		// for ()
		this.page = html`<div>MARKET</div>`
	}

}