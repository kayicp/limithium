import { createActor } from 'declarations/icp_token';

class Token {
  id = null;
  anon = null;
  wallet = null;
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
    this.#init();
  }

  async #init() {
    try {
      const name = this.anon.icrc1_name();
      const symbol = this.anon.icrc1_symbol();
      const decimals = this.anon.icrc1_decimals();
      const fee = this.anon.icrc1_fee();

      this.name = await name;
      this.symbol = await symbol;
      this.decimals = await decimals;
      this.fee = await fee;
    } catch (cause) {
      throw new Error(`get ${token_id} meta`, cause);
    }

    setInterval(async () => {
      const w = this.wallet.get();
      if (w.principal == null) return;
      const acct = { owner: w.principal, subaccount: [] };
      try {
        this.balance = await this.anon.icrc1_balance(acct);        
      } catch (e) {
        console.error('get balance', token_id, e)
      };
    }, 2000);

    setInterval(async () => {
      const w = this.wallet.get();
      if (w.principal == null) return;
      const acct = { owner: w.principal, subaccount: [] };
      try {
        const approval = await this.anon.icrc2_allowance({ account: acct, spender : { owner: vault_id, subaccount: [] } });
        this.allowance = approval.allowance;
        this.expires_at = approval.expires_at.length > 0? approval.expires_at[0] : null;
      } catch (e) {
        console.error('get vault appr', token_id, e);
      };
    }, 2000);
  }
}

export default Token;