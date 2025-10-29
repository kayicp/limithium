import { html } from 'lit-html';

export default class Deposit {
	static PATH = '/deposit';

	constructor(vault) {
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				history.pushState({}, '', Deposit.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Deposit</button>
		`;

		this.page = html`
		<div>
			DEPOSIT
		</div>
		`
	}

}