import { html, render } from 'lit-html';
import { vault_canister } from 'declarations/vault_canister';
import logo from './logo2.svg';
import Wallet from './Wallet/Wallet';
import Vault from './Poller/Vault';

/*
  6AF4AE green
  F68701 orange
  E01201 red
*/

// todo: dont rush building UI, but build data poller first

const network = process.env.DFX_NETWORK;
const identityProvider =
  network === 'ic'
    ? 'https://identity.ic0.app' // Mainnet
    : 'http://rdmx6-jaaaa-aaaaa-aaadq-cai.localhost:5000'; // Local

const wallet = new Wallet();
const vault = new Vault(wallet);

async function clickNav(e) {
  e.preventDefault();
  renderHeader();
}

function renderHeader() {
  let body = html`
    <button>Pairs</button>
    <button>Deposit</button>
    <button>Withdraw</button>
    <button @click=${() => wallet.get().login(
      identityProvider, 
      () => console.log('ok'), 
      (e) => console.error('login err', e)
    )}>Connect Wallet</button>
  `;
  render(body, document.getElementById('header'));
}

class App {
  constructor() {
    renderHeader();
  }
}

export default App;
