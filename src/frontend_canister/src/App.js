import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';
import Balances from './Element/Balances';
import Market from './Element/Market';
import PubSub from '../../util/js/pubsub';
import { Principal } from '@dfinity/principal';
import { renderNotifications } from '../../util/js/notification';

/*
  todo:
  - move notifications to App.js (here)
  - fix limit form, show available balance
  - logo
  - use ckbtc as quote
*/

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
  let page = html`<div class="text-xs text-slate-400">404: Not Found</div>`;
  if (pathn == "/") {
    page = html`<div class="text-sm bg-slate-800/40 rounded-md p-2 ring-1 ring-slate-700">Landing page here</div>`;
  } else if (pathn.startsWith(Balances.PATH)) {
    page = balances.page;
  } else if (pathn.startsWith(Market.PATH)) {
    page = market.page;
  }

  const body = html`
    <div class="min-h-screen flex flex-col">
      <header class="flex items-center gap-2 p-2 bg-slate-900 border-b border-slate-800 sticky top-0 z-10">
        <button
          class="inline-flex items-center px-2 py-1 text-xs rounded-md font-medium bg-slate-800 hover:bg-slate-700 text-slate-100 ring-1 ring-slate-700"
          @click=${() => {
            history.pushState({}, '', '/'); 
            window.dispatchEvent(new PopStateEvent('popstate'));
            _render();
          }}>
          Limithium
        </button>

        <div class="flex items-center gap-2 ml-2">
          ${market.button}
          ${balances.button}
        </div>

        <div class="ml-auto">
          ${wallet.button}
        </div>
      </header>

      <main class="p-3 max-w-6xl mx-auto flex-1 relative">
        ${page}
      </main>

      <footer class="p-2 text-xs text-slate-400">
        © Limithium
      </footer>

      ${renderNotifications()}
    </div>
  `;
  render(body, document.getElementById('root'));
}

class App {
  constructor() {
    _render();
  }
}

export default App;
