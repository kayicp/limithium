import { html } from 'lit-html';

export default class Deposit {
	static PATH = '/deposit';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				this.#render();
				history.pushState({}, '', Deposit.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Deposit</button>
		`;

		this.page = null;
	}

	#render() {
		// for ()
		this.page = html`<div></div>`
	}

}