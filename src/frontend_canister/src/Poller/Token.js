import { createActor } from 'declarations/icp_token';

class Token {
  id = null;
  anon = null;
  wallet = null;
  vault_id = null;

  name = null;
  symbol = null;
  decimals = null;
  fee = null;

  balance = 0;
  allowance = 0;
  expires_at = null;

  constructor(token_id, vault_id, wallet) {
    this.id = token_id;
    this.wallet = wallet;
		this.anon = createActor(token_id);
    this.vault_id = vault_id;
    this.#init();
  }

  async #init() {
    try {
      const [name, symbol, decimals, fee] = await Promise.all([
        this.anon.icrc1_name(),
        this.anon.icrc1_symbol(),
        this.anon.icrc1_decimals(),
        this.anon.icrc1_fee(),
      ]);
      this.name = name;
      this.symbol = symbol;
      this.decimals = decimals;
      this.fee = fee;
    } catch (cause) {
      throw new Error(`get ${token_id} meta`, cause);
    }

    setInterval(async () => {
      const w = this.wallet.get();
      if (w.principal == null) return;
      const account = { owner: w.principal, subaccount: [] };
      const spender = { owner: this.vault_id, subaccount: [] };

      try {
        const [balance, approval] = await Promise.all([
          this.anon.icrc1_balance(account),        
          this.anon.icrc2_allowance({ account, spender }),
        ]);
        this.balance = balance;
        this.allowance = approval.allowance;
        this.expires_at = approval.expires_at.length > 0? approval.expires_at[0] : null;
      } catch (e) {
        console.error('get balance', token_id, e)
      };
    }, 2000);
  }
}

export default Token;