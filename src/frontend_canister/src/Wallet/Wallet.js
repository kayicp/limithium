import InternetIdentity from "./InternetIdentity";
import { html } from 'lit-html';

class Wallet {
  ii = null;
  pubsub = null;
  button = null;

  constructor(pubsub) {
    this.pubsub = pubsub;
    this.ii = new InternetIdentity(pubsub);
    this.pubsub.on('render', () => this.render());
  }

  get() { return this.ii }

  render() {
    const busy = this.get().busy;
    if (this.get().principal) {
      this.btn(busy? "Disconnecting..." : "Disconnect Wallet", busy);
    } else {
      this.btn(busy? "Connecting..." : "Connect Wallet", busy)
    };
    const err = this.get().err;
    if (err) console.error(err); 
  }

  btn(inner, disabled = false) {
    this.button = html`
      <button 
        ?disabled=${disabled}
        @click=${(e) => {
          e.preventDefault();
          if (!this.get().principal) {
            this.get().login();
          } else this.get().logout();
        }}>
        ${inner}
      </button>`;
    return this.button;
  }
}

export default Wallet;