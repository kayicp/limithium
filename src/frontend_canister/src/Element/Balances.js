import { html } from 'lit-html';

export default class Balances {
	static PATH = '/balances';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				this.#render();
				history.pushState({}, '', Balances.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Balances</button>
		`;

		this.page = null;
	}

	#render() {
		if (this.vault.wallet.get().principal == null) {
			return this.page = html`<div>Please connect your wallet to see this</div>`; 
		}

		const tokens = [];
		for (const [tid, t] of this.vault.tokens) {
			tokens.push(html`
<tr>
	<!-- External -->
	<td>
		<ul>
			<li><strong>Balance:</strong> ${t.ext.clean(t.ext.balance)} ${t.ext.symbol}</li>
			<li><strong>Name:</strong> ${t.ext.name}</li>
			<li><strong>Approve fee + Transfer fee:</strong> ${t.ext.clean(t.ext.fee * 2n)} ${t.ext.symbol}</li>
		</ul>
	</td>
	<td>
	<div>
			<button
				type="button"
				?disabled=${t.busy}
				@click=${() => this.vault.deposit(tid)}
			>Deposit →</button>
			<input
				type="text"
				inputmode="decimal"
				pattern="\\d+(?:\\.\\d{0,${t.ext.decimals}})?"
				placeholder="Amount"
				.value=${t.amount ?? ''}
				?disabled=${t.busy}
				@keydown=${(e) => {
					// disallow e, E, +, -, multiple decimals etc
					if (['e','E','+','-'].includes(e.key)) {
						e.preventDefault();
					}
				}}
				@input=${(e) => {
					const input = e.target.value;
					// strip unwanted chars, allow only digits + optional dot + upto decimals
					const cleaned = input
						.replace(/[eE\+\-]/g, '')
						.replace(/[^0-9\.]/g, '')
						// ensure only one dot
						.replace(/\.(?=.*\.)/g, '');
					// optionally limit decimals after dot
					const parts = cleaned.split('.');
					if (parts[1]?.length > t.ext.decimals) {
						t.amount = parts[0] + '.' + parts[1].slice(0, t.ext.decimals);
					} else {
						t.amount = cleaned;
					}
				}}
			>
			<button
				type="button"
				?disabled=${t.busy}
				@click=${() => this.vault.withdraw(tid)}
			>← Withdraw</button>
		</div>
	</td>
	<!-- Internal -->
	<td>
		<ul>
			<li><strong>Balance:</strong> ${t.ext.clean(t.balance)} ${t.ext.symbol}</li>
			<li><strong>Deposit fee:</strong> 0 ${t.ext.symbol}</li>
			<li><strong>Withdrawal fee:</strong> ${t.ext.clean(t.withdrawal_fee)} ${t.ext.symbol}</li>
		</ul>
	</td>
</tr>
`);
		}
		this.page = html`
<div>
	<table border="1" cellspacing="0" cellpadding="6">
		<tr>
			<th>External</th>
			<th></th>
			<th>Internal</th>
		</tr>
		${tokens}
	</table>
</div>
`
	}

}