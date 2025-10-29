import InternetIdentity from "./InternetIdentity";
import PubSub from "../../../util/js/pubsub";
import { html } from 'lit-html';

class Wallet {
  ii = null;
  pubsub = new PubSub();
  button = null;

  constructor() {
		this.ii = new InternetIdentity(this.pubsub);
  }

  get() { return this.ii }

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