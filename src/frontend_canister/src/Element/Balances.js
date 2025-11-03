import { html } from 'lit-html';

export default class Balances {
	static PATH = '/balances';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button @click=${(e) => {
				e.preventDefault();
				if (window.location.pathname.startsWith(Balances.PATH)) return;
				this.#render();
				history.pushState({}, '', Balances.PATH);
				window.dispatchEvent(new PopStateEvent('popstate'));
			}}>Balances</button>
		`;

		this.vault.pubsub.on('render', () => this.#render());
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
			<li><strong>Approve fee + Transfer fee:</strong> ${t.ext.clean(t.ext.fee + t.ext.fee)} ${t.ext.symbol}</li>
		</ul>
	</td>

	<td>
		<div>
			<!-- Operation select -->
			<select
				?disabled=${t.busy}
				.value=${t.operation ?? 'deposit'}
				@change=${(e) => { t.operation = e.target.value; }}
			>
				<option value="deposit">Deposit</option>
				<option value="withdraw">Withdraw</option>
			</select>

			<!-- Amount input: digits + optional one dot, decimals limited to t.ext.decimals -->
			<input
				type="text"
				inputmode="decimal"
				pattern="\\d+(?:\\.\\d{0,${Number(t.ext.decimals)}})?"
				placeholder="Amount"
				.value=${t.amount ?? ''}
				?disabled=${t.busy}
				@keydown=${(e) => {
					// disallow e, E, +, - and disallow a second dot
					if (['e','E','+','-'].includes(e.key)) {
						e.preventDefault();
						return;
					}
					if (e.key === '.' && e.target.value.includes('.')) {
						e.preventDefault();
						return;
					}
				}}
				@input=${(e) => {
					const input = e.target.value;
					// Keep only digits and dots
					let cleaned = input.replace(/[^0-9.]/g, '');

					// Leave only the first dot (remove any subsequent dots)
					const firstDot = cleaned.indexOf('.');
					if (firstDot !== -1) {
						cleaned = cleaned.slice(0, firstDot + 1) + cleaned.slice(firstDot + 1).replace(/\./g, '');
					}

					// Enforce decimals limit from t.ext.decimals
					const parts = cleaned.split('.');
					if (parts[1]?.length > t.ext.decimals) {
						t.amount = parts[0] + '.' + parts[1].slice(0, t.ext.decimals);
					} else {
						t.amount = cleaned;
					}
				}}
			>

			<!-- Confirm button triggers deposit or withdraw based on select -->
			<button
				type="button"
				?disabled=${t.busy || !t.amount}
				@click=${() => {
					if (!t.amount) return;
					if ((t.operation ?? 'deposit') === 'deposit') {
						this.vault.deposit(tid);
					} else {
						this.vault.withdraw(tid);
					}
				}}
			>Confirm</button>
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
`); // todo: deposit only show deposit fee, withdraw only show withdraw fee
		}
		this.page = html`
<div>
	<table border="1" cellspacing="0" cellpadding="6">
		<tr>
			<th>Your Wallet</th>
			<th></th>
			<th>Vault</th>
		</tr>
		${tokens}
	</table>
</div>
`
	}

}

// todo: refresh button to reset all pollers