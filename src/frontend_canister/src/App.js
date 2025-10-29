import { html, render } from 'lit-html';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';
import WalletConstant from './Wallet/Constants';
import Deposit from './Element/Deposit';
import Withdraw from './Element/Withdraw';

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

const wallet = new Wallet();
wallet.pubsub.on(WalletConstant.IS_AUTH_ERR, () => {
  wallet.btn("Connect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.CLIENT_ERR, () => {
  wallet.btn("Connect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.ANON_OK, () => {
  wallet.btn("Connect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.LOGIN_BUSY, () => {
  wallet.btn("Connecting...", true);
  render0()
});
wallet.pubsub.on(WalletConstant.LOGIN_OK, () => {
  console.log('user_p:\n', wallet.get().principal.toText());
  wallet.btn("Disconnect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.LOGIN_ERR, () => {
  wallet.btn("Connect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.LOGOUT_BUSY, () => {
  wallet.btn("Disconnecting...", true)
  render0()
});
wallet.pubsub.on(WalletConstant.LOGOUT_OK, () => {
  wallet.btn("Connect Wallet");
  render0()
});
wallet.pubsub.on(WalletConstant.LOGOUT_ERR, () => {
  wallet.btn("Disconnect Wallet");
  render0()
});

const vault = new Vault(wallet);
const deposit = new Deposit(vault);
const withdraw = new Withdraw(vault);

// todo: poller wait 1s every new update, use events, 

window.addEventListener('popstate', render0);

function render0() {
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
    render0();
  }
}

export default App;
