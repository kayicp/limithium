import { idlFactory, canisterId } from 'declarations/vault_canister';
import Token from './Token';
import Book from './Book';
import { HttpAgent } from '@dfinity/agent';
import { wait } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';

class Vault {
  wallet = null;
  anon = null;

  tokens = new Map();
  books = new Map();

  constructor(wallet) {
    this.wallet = wallet;
    this.#init();
  }

  async #init() {
    try {
      this.anon = await genActor(idlFactory, canisterId);
      const result = await this.anon.vault_executors([], []);
      
      for (const p of result) {
        this.books.set(p, new Book(p, this.wallet));
      }
    } catch (cause) {
      throw new Error('get books:', { cause });
    }

    try {
      const result = await this.anon.vault_tokens([], []);
      
      for (const p of result) {
        this.tokens.set(p, {
          withdrawal_fee: 0,
          balance: 0,
          actor: new Token(p, canisterId, this.wallet)
        });
      }      
    } catch (cause) {
      throw new Error('get tokens:', { cause });
    }
    if (this.tokens.size == 0) throw new Error('no tokens');
  
    const t_ids = [...this.tokens.keys()];

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
      const user_p = this.wallet.get().principal;
      if (user_p == null) return;
      try {
        const account = { owner: user_p, subaccount: [] };
        const accounts = t_ids.map(token => ({ token, account }));

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