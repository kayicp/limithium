import { idlFactory, canisterId } from 'declarations/vault_canister';
import Token from './Token';
import Book from './Book';
import { wait, retry } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';
import Principal from '../../../util/js/principal';

class Vault {
  pubsub = null;
  err = null;

  wallet = null;
  anon = null;

  tokens = new Map();
  books = new Map();

  constructor(wallet) {
    this.wallet = wallet;
    this.pubsub = wallet.pubsub;
    this.#init();
  }

  #render(err = null) {
    this.err = err;
    this.pubsub.emit('render');
  }

  async #init() {
    try {
      this.anon = await genActor(idlFactory, canisterId);
      const result = await this.anon.vault_executors([], []);
      for (const p of result) {
        this.books.set(p, new Book(p, this.wallet, this.pubsub));
      }
      this.#render();
    } catch (cause) {
      const err = new Error('get books', { cause });
      return this.#render(err);
    }

    try {
      const result = await this.anon.vault_tokens([], []);
      for (const p of result) {
        this.tokens.set(p, {
          withdrawal_fee: 0,
          balance: 0,
          actor: new Token(p, Principal.fromText(canisterId), this.wallet)
        });
      }
      this.#render();
    } catch (cause) {
      const err = new Error('get tokens:', { cause });
      return this.#render(err);
    }
  
    const t_ids = [...this.tokens.keys()];

    try {
      const withdrawal_fees = await this.anon.vault_withdrawal_fees_of(t_ids);
      
      const fees = [];
      for (let i = 0; i < t_ids.length; i++) {
        const token_id = t_ids[i];
        const withdrawal_fee = withdrawal_fees[i];
        
        if (withdrawal_fee.length > 0) {
          this.tokens.get(token_id).withdrawal_fee = withdrawal_fee[0];
          fees.push({ id: token_id, fee: withdrawal_fee[0] });
        }
      }
      this.#render();
    } catch (cause) {
      const err = new Error('get withdrawal_fees:', { cause });
      return this.#render(err);
    }

    let delay = 1000;
    while (true) {
      const user_p = this.wallet.get().principal;
      if (user_p == null) return;
      try {
        let has_new = false;
        const account = { owner: user_p, subaccount: [] };
        const accounts = t_ids.map(token => ({ token, account }));
  
        const bals = await this.anon.vault_unlocked_balances_of(accounts);
  
        for (let i = 0; i < t_ids.length; i++) {
          const t = this.tokens.get(t_ids[i]);
          if (t.balance != bals[i]) has_new = true;
          t.balance = bals[i];
        }
        if (has_new) this.#render();
        delay = retry(has_new, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error('get unlocked_balances:', { cause });
        this.#render(err);
      }
      await wait(delay)
    }
  }

}

export default Vault;