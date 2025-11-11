import { html } from 'lit-html';

export default class Balances {
	static PATH = '/balances';

	constructor(vault) {
		this.vault = vault;
		this.button = html`
		<button 
			class="inline-flex items-center px-2 py-1 text-xs rounded-md font-medium bg-slate-800 hover:bg-slate-700 text-slate-100 ring-1 ring-slate-700"
			@click=${(e) => {
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
    <div class="w-full bg-slate-800/40 ring-1 ring-slate-700 rounded-md p-3 mb-3 text-xs
                grid gap-2 grid-cols-1 sm:grid-cols-3 items-start">
      <!-- Wallet info (left) -->
      <div class="flex flex-col gap-1">
        <ul class="list-none p-0 m-0 mt-1 text-slate-200">
          <li><span class="text-slate-400">Balance:</span> ${t.ext.clean(t.ext.balance)} ${t.ext.symbol}</li>
          <li><span class="text-slate-400">Name:</span> ${t.ext.name}</li>
          <li><span class="text-slate-400">Approve fee + Transfer fee:</span> ${t.ext.clean(t.ext.fee + t.ext.fee)} ${t.ext.symbol}</li>
        </ul>
      </div>

      <!-- Controls (middle) -->
      <!-- min-w-0 prevents children from overflowing the grid column -->
      <div class="flex flex-col gap-2 items-stretch justify-center min-w-0">
        <!-- stacked on mobile, row on sm+; min-w-0 allows input to shrink -->
        <div class="flex flex-col sm:flex-row gap-2 items-stretch w-full min-w-0">
          <select
            class="w-full sm:w-auto bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700"
            ?disabled=${t.busy}
            .value=${t.operation ?? 'deposit'}
            @change=${(e) => t.operation = e.target.value}
          >
            <option value="deposit">Deposit into the Vault</option>
            <option value="withdraw">Withdraw from the Vault</option>
            <option value="transfer">Transfer to another Wallet</option>
          </select>

          <input
            class="flex-1 min-w-0 w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700 placeholder:text-slate-500"
            type="text"
            inputmode="decimal"
            pattern="\\d+(?:\\.\\d{0,${Number(t.ext.decimals)}})?"
            placeholder="Amount"
            .value=${t.amount}
            ?disabled=${t.busy}
            @keydown=${(e) => {
              if (['e','E','+','-'].includes(e.key)) { e.preventDefault(); return; }
              if (e.key === '.' && e.target.value.includes('.')) { e.preventDefault(); return; }
            }}
            @input=${(e) => {
              const input = e.target.value;
              let cleaned = input.replace(/[^0-9.]/g, '');
              const firstDot = cleaned.indexOf('.');
              if (firstDot !== -1) {
                cleaned = cleaned.slice(0, firstDot + 1) + cleaned.slice(firstDot + 1).replace(/\./g, '');
              }
              const parts = cleaned.split('.');
              if (parts[1]?.length > t.ext.decimals) {
                t.amount = parts[0] + '.' + parts[1].slice(0, t.ext.decimals);
              } else {
                t.amount = cleaned;
              }
            }}
          >
          ${t.operation == 'transfer'? html`<input
            class="flex-1 min-w-0 w-full bg-slate-800 text-slate-100 text-xs px-2 py-1 rounded-md ring-1 ring-slate-700 placeholder:text-slate-500"
            type="text"
            placeholder="Receiver's Principal"
            .value=${t.receiver}
            ?disabled=${t.busy}
            @input=${(e) => t.receiver = e.target.value}
            >` : html``}
        </div>

        <div class="flex items-center gap-2">
          <button
            class="w-full sm:w-auto px-2 py-1 text-xs rounded-md font-medium bg-slate-800 hover:bg-slate-700 text-slate-100 ring-1 ring-slate-700 disabled:opacity-50 disabled:cursor-not-allowed"
            type="button"
            ?disabled=${t.busy || !t.amount}
            @click=${() => {
              if (!t.amount) return;
              const opr = t.operation ?? 'deposit';
              if (opr == 'deposit') {
                this.vault.deposit(t);
              } else if (opr == 'withdraw') {
                this.vault.withdraw(t);
              } else {
                this.vault.transfer(t);
              }
            }}
          >Confirm</button>
        </div>
      </div>

      <!-- Vault info (right) -->
      <div class="flex flex-col gap-1 break-words">
        <ul class="list-none p-0 m-0 mt-1 text-slate-200">
          <li><span class="text-slate-400">Balance:</span> ${t.ext.clean(t.balance)} ${t.ext.symbol}</li>
          <li><span class="text-slate-400">Deposit fee:</span> 0 ${t.ext.symbol}</li>
          <li><span class="text-slate-400">Withdrawal fee:</span> ${t.ext.clean(t.withdrawal_fee)} ${t.ext.symbol}</li>
        </ul>
      </div>
    </div>
  `);
}
this.page = html`
  <div class="w-full max-w-6xl mx-auto">
    <!-- Header row (labels) -->
    <div class="hidden sm:grid grid-cols-3 gap-3 mb-2 text-xs text-slate-400">
      <div>Your Wallet</div>
      <div>Action</div>
      <div>Vault</div>
    </div>

    <!-- Token cards -->
    <div>
      ${tokens}
    </div>
  </div>
`;

	}

}

// todo: refresh button to reset all pollers