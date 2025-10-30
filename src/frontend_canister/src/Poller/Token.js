import { idlFactory } from 'declarations/icp_token';
import { wait, retry } from '../../../util/js/wait';
import { genActor } from '../../../util/js/actor';

class Token {

  static META = "token-meta";
  static BALANCE = "token-balance";
  static ABORT = "token-abort";
  static ERR = "token-err";

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

  constructor(token_id, vault_id, wallet, pubsub) {
    this.id = token_id;
    this.wallet = wallet;
    this.vault_id = vault_id;
    this.pubsub = pubsub;
    this.#init();
  }

  async #init() {
    try {
      this.anon = await genActor(idlFactory, this.id);
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
      this.pubsub.emit(Token.META, { id: this.id });
    } catch (cause) {
      const err = new Error(`token meta:`, { cause });
      this.pubsub.emit(Token.ABORT, { id: this.id, err });
      throw err;
    }

    let delay = 1000;
    while(true) {
      try {
        const account = { owner: this.wallet.get().principal, subaccount: [] };
        const spender = { owner: this.vault_id, subaccount: [] };
        let has_change = false;
        if (account.owner != null) {
          const [balance, approval] = await Promise.all([
            this.anon.icrc1_balance_of(account),        
            this.anon.icrc2_allowance({ account, spender }),
          ]);
          if (this.balance != balance) has_change = true;
          this.balance = balance;

          if (this.allowance != approval.allowance) has_change = true;
          this.allowance = approval.allowance;

          if (this.expires_at != approval.expires_at[0]) has_change = true;
          this.expires_at = approval.expires_at[0];
          delay = retry(has_change, delay);
          this.pubsub.emit(Token.BALANCE, { id: this.id });
        } else delay = retry(true, delay);
      } catch (cause) {
        delay = retry(false, delay);
        const err = new Error('token balance', { cause });
        this.pubsub.emit(Token.ERR, { id: this.id, err });
      };
      await wait(delay)
    }
  }
}

export default Token;