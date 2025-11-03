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
		const books = [];
		for (const [book_id, book] of this.vault.books) {
			// if (book.)
			books.push(html`
	
			`);
		}
		this.page = html`<div></div>`
	}

}