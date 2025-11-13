import { idlFactory, canisterId } from 'declarations/vault_canister';
import Token from './Token';
import Book from './Book';
import { wait, retry } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';
import { nano2date } from '../../../util/js/bigint';
import { Principal } from '@dfinity/principal';

class Vault {
  err = null;

  wallet = null;
  anon = null;

  tokens = new Map();

  selected_book = null;
  books = new Map();

  constructor(wallet) {
    this.wallet = wallet;
    this.notif = wallet.notif;
    this.pubsub = wallet.notif.pubsub;
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
      return this.notif.errorToast('Vault: Get Executors', cause);
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
      return this.notif.errorToast('Vault: Get Tokens', cause);
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
      return this.notif.errorToast('Vault: Get Withdrawal Fees', cause);
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
        this.notif.errorToast('Vault: Get Unlocked Balances', cause);
      }

      if (await wait(delay, this.pubsub) == 'refresh') delay = 1000;
    }
  }

  async deposit(t){
    const amt = t.ext.raw(t.amount);
    if (amt < 1n) { // todo: check if lower than withdrawal fee
      return this.notif.errorPopup(`Amount input of ${t.ext.symbol} token`, 'Must be larger than 0.')
    }
    t.busy = true;
    this.#refresh();

    if (amt < t.ext.allowance || (t.ext.expires_at && nano2date(t.ext.expires_at) < new Date())) {
      try {
        const res = await t.ext.approve(amt);
        if ('Err' in res) {
          t.busy = false;
          return this.notif.errorPopup(`${t.ext.symbol} token post approval failed`, JSON.stringify(res.Err))
        }
        this.notif.successToast(`${t.ext.symbol} token approval success`, `Block: ${res.Ok}`)
      } catch (cause) {
        t.busy = false;
        return this.notif.errorPopup(`${t.ext.symbol} token approval failed`, cause)
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
        return this.notif.errorPopup(`Post deposit ${t.ext.symbol} failed`, JSON.stringify(res.Err))
      }
      t.amount = '';
      this.notif.successToast(`Deposit ${t.ext.symbol} success`, `Block: ${res.Ok}`)
    } catch (cause) {
      t.busy = false;
      return this.notif.errorPopup(`Deposit ${t.ext.symbol} failed`, cause)
    }
  }

  async withdraw(t) {
    const amt = t.ext.raw(t.amount);
    if (amt < 1n) { // todo: check if lower than withdrawal fee
      return this.notif.errorPopup(`Amount input of ${t.ext.symbol} token`, 'Must be larger than 0.')
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
        return this.notif.errorPopup(`Post withdraw ${t.ext.symbol} failed`, JSON.stringify(res.Err))
      }
      t.amount = '';
      this.notif.successToast(`Withdraw ${t.ext.symbol} success`, `Block: ${res.Ok}`)
    } catch (cause) {
      t.busy = false;
      return this.notif.errorPopup(`Withdraw ${t.ext.symbol} failed`, cause)
    }
  }

  async transfer(t) {
    const amt = t.ext.raw(t.amount);
    if (amt < 1n) {
      return this.notif.errorPopup(`Amount input of ${t.ext.symbol} token`, 'Must be larger than 0.')
    }

    const rcvr = t.receiver.trim();
    if (rcvr.length == 0) {
      return this.notif.errorPopup(`Receiver input of ${t.ext.symbol} token`, 'Must be a principal ID')
    }

    let rcvr_p = null;
    try {
      rcvr_p = Principal.fromText(rcvr);
    } catch (cause) {
      return this.notif.errorPopup(`Receiver input of ${t.ext.symbol} token`, cause)
    }

    t.busy = true;
    this.#render();
    try {
      const res = await t.ext.transfer(amt, rcvr_p);
      t.busy = false;
      if ('Err' in res) {
        return this.notif.errorPopup(`Post transfer ${t.ext.symbol} failed`, JSON.stringify(res.Err))
      }
      t.amount = '';
      t.receiver = '';
      this.notif.successToast(`Transfer ${t.ext.symbol} success`, `Block: ${res.Ok}`)
    } catch (cause) {
      t.busy = false;
      return this.notif.errorPopup(`Transfer ${t.ext.symbol} failed`, cause)
    }
  }
}

export default Vault;