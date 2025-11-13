import InternetIdentity from "./InternetIdentity";
import { html } from 'lit-html';

class Wallet {
  ii = null;
  button = null;

  constructor(notif) {
    this.ii = new InternetIdentity(notif);
    this.notif = notif;
    this.notif.pubsub.on('render', () => this.render());
  }

  get() { return this.ii }

  render() {
    const busy = this.get().busy;
    if (this.get().principal) {
      this.btn(busy? "Disconnecting..." : "Disconnect Wallet", busy);
    } else {
      this.btn(busy? "Connecting..." : "Connect Wallet", busy);
    };
    const err = this.get().err;
    if (err) console.error(err); 
  }
  
  btn(inner, disabled = false) {
    this.button = html`
      <button 
        class="inline-flex items-center px-2 py-1 text-xs rounded-md font-medium bg-slate-800 hover:bg-slate-700 text-slate-100 ring-1 ring-slate-700 disabled:opacity-50 disabled:cursor-not-allowed"
        ?disabled=${disabled}
        @click=${(e) => this.get().click(e)}>
        ${inner}
      </button>`;
    return this.button;
  }
}

export default Wallet;