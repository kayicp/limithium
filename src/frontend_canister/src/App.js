import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';

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

let wallet = null;
let vault = null;

async function clickNav(e) {
  e.preventDefault();
  renderHeader();
}

function renderHeader() {
  let body = html`
    <button>Pairs</button>
    <button>Deposit</button>
    <button>Withdraw</button>
    <button @click=${async () => {
      await wallet.get().login();
      console.log('p:', wallet.get().principal);
    }}>Connect Wallet</button>
  `;
  render(body, document.getElementById('header'));
}

class App {
  constructor() {
    wallet = new Wallet();
    vault = new Vault(wallet);
    renderHeader();
  }
}

export default App;
