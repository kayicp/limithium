import { idlFactory, canisterId } from 'declarations/vault_canister';
import Token from './Token';
import Book from './Book';
import { wait, retry } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';
import { nano2date } from '../../../util/js/bigint';
import Principal from '../../../util/js/principal';

class Vault {
  pubsub = null;
  err = null;

  wallet = null;
  anon = null;

  tokens = new Map();

  selected_book = null;
  books = new Map();

  constructor(wallet) {
    this.wallet = wallet;
    this.pubsub = wallet.pubsub;
    this.#init();
  }

  #refresh() {
    this.pubsub.emit('refresh');
    this.#render();
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
        this.books.set(p.toText(), new Book(p, this.wallet, this.pubsub));
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
        this.tokens.set(p.toText(), {
          busy: false,
          amount: '',
          receiver: '',
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
  
    const t_ids = [];
    const t_id_txts = []
    for (const [t_id, t] of this.tokens) {
      t_id_txts.push(t_id);
      t_ids.push(t.ext.id);
    };

    try {
      const withdrawal_fees = await this.anon.vault_withdrawal_fees_of(t_ids);
      
      for (let i = 0; i < t_ids.length; i++) {
        const t_id_txt = t_id_txts[i];
        const withdrawal_fee = withdrawal_fees[i];
        
        if (withdrawal_fee.length > 0) {
          this.tokens.get(t_id_txt).withdrawal_fee = withdrawal_fee[0];
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
          const t = this.tokens.get(t_id_txts[i]);
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

      if (await wait(delay, this.pubsub) == 'refresh') delay = 1000;
    }
  }

  async deposit(t){
    const amt = t.ext.raw(t.amount);
    if (amt == 0n) { // todo: check if lower than withdrawal fee
      const err = new Error(`approve deposit ${amt} ${t.ext.symbol}: amount is zero`);
      return this.#render(err);
    }

    t.busy = true;
    this.#refresh();

    if (amt < t.ext.allowance || (t.ext.expires_at && nano2date(t.ext.expires_at))) {
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
    };

    try {
      const user = await genActor(idlFactory, canisterId, this.wallet.get().agent);
      const res = await user.vault_deposit({
        subaccount: [],
        canister_id: t.ext.id,
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
      t.amount = '';
      this.#refresh();
    } catch (cause) {
      const err = new Error(`deposit ${amt} ${t.ext.symbol}`, { cause });
      t.busy = false;
      return this.#render(err);
    }
  }

  async withdraw(t) {
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
        canister_id: t.ext.id,
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
      t.amount = '';
      this.#refresh();
    } catch (cause) {
      const err = new Error(`withdraw ${amt} ${t.ext.symbol}`, { cause });
      t.busy = false;
      return this.#render(err);
    }
  }

  async transfer(t) {
    const amt = t.ext.raw(t.amount);
    if (amt == 0n) { // todo: check if lower than withdrawal fee
      const err = new Error(`transfer: amount is zero`);
      return this.#render(err);
    }

    const rcvr = t.receiver.trim();
    if (rcvr.length == 0) {
      const err = new Error(`transfer: receiver is empty`);
      return this.#render(err);
    }

    let rcvr_p = null;
    try {
      rcvr_p = Principal.fromText(rcvr);
    } catch (cause) {
      const err = new Error(`transfer: receiver is not a principal`);
      return this.#render(err);
    }

    t.busy = true;
    this.#render();
    try {
      const res = await t.ext.transfer(amt, rcvr_p);
      t.busy = false;
      if ('Err' in res) {
        const err = new Error(`post transfer ${amt} ${t.ext.symbol} to ${rcvr}: ${JSON.stringify(res.Err)}`);
        return this.#render(err);
      }
      t.amount = '';
      t.receiver = '';
      this.#refresh();
    } catch (cause) {
      const err = new Error(`transfer ${amt} ${t.ext.symbol} to ${rcvr}`, { cause });
      t.busy = false;
      this.#render(err);
    }
  }
}

export default Vault;