import { createActor, canisterId } from 'declarations/vault_canister';
import Token from './Token';

class Vault {
  id = null;
  wallet = null;
  anon = null;

  tokens = new Map();

  constructor(wallet) {
		this.id = canisterId
    this.wallet = wallet;
    this.anon = createActor(canisterId);
    this.#init();
  }

  async #init() {
    try {
      const result = await this.anon.vault_tokens([], []);
      
      for (const p of result) {
        this.tokens.set(p, { 
          min_deposit: 0, 
          withdrawal_fee: 0,
          balance: 0,
          actor: new Token(p, canisterId, wallet)
        });
      }      
    } catch (cause) {
      throw new Error('get tokens:', { cause });
    }
    if (this.tokens.size == 0) throw new Error('no tokens');
  
    const t_ids = [...this.tokens.keys()];
    
    try {
      const min_deposits = await this.anon.vault_min_deposits_of(t_ids);
      
      for (let i = 0; i < t_ids.length; i++) {
        const token_id = t_ids[i];
        const min_deposit = min_deposits[i]; // 
        if (min_deposit.length > 0) {
          this.tokens.get(token_id).min_deposit = min_deposit[0];
        }
      }
    } catch (cause) {
      throw new Error('get min_deposits:', { cause });
    }
  
    try {
      const withdrawal_fees = await this.anon.vault_withdrawal_fees_of(t_ids);
      
      for (let i = 0; i < t_ids.length; i++) {
        const token_id = t_ids[i];
        const withdrawal_fee = withdrawal_fees[i];
        
        if (withdrawal_fee.length > 0) {
          this.tokens.get(token_id).withdrawal_fee = withdrawal_fee[0];
        }
      }
    } catch (cause) {
      throw new Error('get withdrawal_fees:', { cause });
    }

    setInterval(async () => {
      // Get unlocked balances
      const p = this.wallet.get().principal;
      if (p == null) return;
      try {
        const accounts = t_ids.map(token_id => ({
          token: token_id,
          account: { owner: p, subaccount: [] }
        }));

        const bals = await this.anon.vault_unlocked_balances_of(accounts);

        for (let i = 0; i < t_ids.length; i++) {
          this.tokens.get(t_ids[i]).balance = bals[i];
        }
      } catch (cause) {
        throw new Error('get unlocked_balances:', { cause });
      }
    }, 2000);
  }
}

export default Vault;