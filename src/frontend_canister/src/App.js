import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';
import Deposit from './Element/Deposit';
import Withdraw from './Element/Withdraw';
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
const deposit = new Deposit(vault);
const withdraw = new Withdraw(vault);

pubsub.on('render', _render);
window.addEventListener('popstate', _render);

function _render() {
  const pathn = window.location.pathname;
  let page = html`<h1>404: Not Found</h1>`;
  if (pathn == "/") {
    page = html`<p>hello world</p>`
  } else if (pathn.includes(Deposit.PATH)) {
    page = deposit.page;
  } else if (pathn.includes(Withdraw.PATH)) {
    page = withdraw.page;
  }

  const body = html`
    <div>
      <button>Market</button>
      ${deposit.button}
      ${withdraw.button}
      ${wallet.button}
    </div>
    ${page}
  `;
  render(body, document.getElementById('root'));
}

class App {
  constructor() {
    _render();
  }
}

export default App;
