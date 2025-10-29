import { html } from 'lit-html';

export default class Withdraw {
	static PATH = '/withdraw';

	constructor(vault) {
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				history.pushState({}, '', Withdraw.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Withdraw</button>
		`;

		this.page = html`
		<div>
			WITHDRAW
		</div>
		`
	}

}