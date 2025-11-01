import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';
import Balances from './Element/Balances';
import Market from './Element/Market';
import PubSub from '../../util/js/pubsub';

/*
  6AF4AE green
  F68701 orange
  E01201 red
*/

console.log('env.dfx_net', process.env.DFX_NETWORK);

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
const deposit = new Balances(vault);
const market = new Market(vault);

pubsub.on('render', _render);
window.addEventListener('popstate', _render);

function _render() {
  const pathn = window.location.pathname;
  let page = html`<h1>404: Not Found</h1>`;
  if (pathn == "/") {
    page = html`<p>hello world</p>`
  } else if (pathn.includes(Balances.PATH)) {
    page = deposit.page;
  } else if (pathn.includes(Market.PATH)) {
    page = market.page;
  }

  const body = html`
    <div>
      ${market.button}
      ${deposit.button}
      ${wallet.button}
    </div>
    ${page}
    <div>footer</div>
  `;
  render(body, document.getElementById('root'));
}

class App {
  constructor() {
    _render();
  }
}

export default App;
