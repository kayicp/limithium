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
    if (err)  console.error(err);
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
      const vault_id = Principal.fromText(canisterId);
      for (const p of result) {
        this.tokens.set(p, {
          busy: false,
          amount: '',
          operation: 'deposit',
          withdrawal_fee: 0n,
          balance: 0n,
          ext: new Token(p, vault_id, this.wallet)
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

  async deposit(token_id){
    const t = this.tokens.get(token_id);
    const amt = t.ext.raw(t.amount);
    if (amt == 0n) { // todo: check if lower than withdrawal fee
      const err = new Error(`approve deposit ${amt} ${t.ext.symbol}: amount is zero`);
      return this.#render(err);
    }

    t.busy = true;
    this.#render();
    // todo: if approval is enough, dont approve
    try {
      const res = await t.ext.approve(amt);
      if ('Err' in res) {
        const err = new Error(`post approve deposit ${amt} ${t.ext.symbol}: ${JSON.stringify(res.Err)}`);
        t.busy = false;
        return this.#render(err);
      }
    } catch (cause) {
      const err = new Error(`approve deposit ${amt} ${t.ext.symbol}`, { cause });
      t.busy = false;
      return this.#render(err);
    }

    try {
      const user = await genActor(idlFactory, canisterId, this.wallet.get().agent);
      const res = await user.vault_deposit({
        subaccount: [],
        canister_id: token_id,
        amount: amt,
        fee: [],
        memo: [],
        created_at: [],
      });
      t.busy = false;
      if ('Err' in res) {
        const err = new Error(`post deposit ${amt} ${t.ext.symbol}: ${JSON.stringify(res.Err)}`);
        return this.#render(err);
      }
      t.amount = '0';
      this.#render();
    } catch (cause) {
      const err = new Error(`deposit ${amt} ${t.ext.symbol}`, { cause });
      t.busy = false;
      return this.#render(err);
    }
  }

  async withdraw(token_id) {
    const t = this.tokens.get(token_id);
    const amt = t.ext.raw(t.amount);
    if (amt == 0n) { // todo: check if lower than withdrawal fee
      const err = new Error(`withdraw ${amt} ${t.ext.symbol}: amount is zero`);
      return this.#render(err);
    }

    t.busy = true;
    this.#render();
    try {
      const user = await genActor(idlFactory, canisterId, this.wallet.get().agent);
      const res = await user.vault_withdraw({
        subaccount: [],
        canister_id: token_id,
        amount: amt,
        fee: [],
        memo: [],
        created_at: [],
      });
      t.busy = false;
      if ('Err' in res) {
        const err = new Error(`post withdraw ${amt} ${t.ext.symbol}: ${JSON.stringify(res.Err)}`);
        return this.#render(err);
      }
      t.amount = '0';
      this.#render();
    } catch (cause) {
      const err = new Error(`withdraw ${amt} ${t.ext.symbol}`, { cause });
      t.busy = false;
      return this.#render(err);
    }
  }
}

export default Vault;