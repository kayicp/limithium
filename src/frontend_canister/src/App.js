import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';
import Balances from './Element/Balances';
import Market from './Element/Market';
import PubSub from '../../util/js/pubsub';
import { Principal } from '@dfinity/principal';

/*
  6AF4AE green
  F68701 orange
  E01201 red
*/

console.log('env.dfx_net', process.env.DFX_NETWORK);

Principal.prototype.toString = function () {
  return this.toText();
}
Principal.prototype.toJSON = function () {
  return this.toString();
}
BigInt.prototype.toJSON = function () {
  return this.toString();
};

const blob2hex = blob => Array.from(blob).map(byte => byte.toString(16).padStart(2, '0')).join('');
Uint8Array.prototype.toJSON = function () {
  return blob2hex(this) // Array.from(this).toString();
}

const pubsub = new PubSub();
const wallet = new Wallet(pubsub);
const vault = new Vault(wallet);
const balances = new Balances(vault);
const market = new Market(vault);

pubsub.on('render', _render);
window.addEventListener('popstate', _render);

function _render() {
  const pathn = window.location.pathname;
  let page = html`<div>404: Not Found</div>`;
  if (pathn == "/") {
    page = html`<div>Landing page here</div>`
  } else if (pathn.startsWith(Balances.PATH)) {
    page = balances.page;
  } else if (pathn.startsWith(Market.PATH)) {
    page = market.page;
  }

  const body = html`
    <header>
      <button>Home Logo</button>
      ${market.button}
      ${balances.button}
      ${wallet.button}
    </header>
    <main>
      ${page}
    </main>
    <footer></footer>
  `;
  render(body, document.getElementById('root'));
}

class App {
  constructor() {
    _render();
  }
}

export default App;
