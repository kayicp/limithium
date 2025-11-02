import { AuthClient } from "@dfinity/auth-client";
import { HttpAgent } from '@dfinity/agent';
import Principal from '../../../util/js/principal';
import { AccountIdentifier } from '@dfinity/ledger-icp'

const network = process.env.DFX_NETWORK;
const identityProvider =
  network === 'ic'
    ? 'https://identity.ic0.app' // Mainnet
    : 'http://rdmx6-jaaaa-aaaaa-aaadq-cai.localhost:5000'; // Local

const DAYS_30_NANOS = BigInt(30 * 24 * 60 * 60 * 1000 * 1000 * 1000);

class InternetIdentity {
	busy = false;
	err = null;
	pubsub = null;

  ii = null;
	agent = null;
	principal = null;
	accountid = null;

  constructor(pubsub) {
		this.pubsub = pubsub;
		this.#init();
  }

	#render(busy = false, err = null) {
		this.busy = busy;
		this.err = err;
		this.pubsub.emit('render');
	}

  async #init() {
		this.#render(true);
    if (this.ii == null) try {
      this.ii = await AuthClient.create();
    } catch (cause) {
			const err = new Error('init client', { cause });
			return this.#render(false, err);
    }
    try {
      if (await this.ii.isAuthenticated()) {
				// proceed to #authed
			} else return this.#render();
    } catch (cause) {
			const err = new Error('init auth', { cause });
			return this.#render(false, err);
    }
		try {
			await this.#authed();
			this.#render(false);
		} catch (cause) {
			const err = new Error('init login', { cause });
			return this.#render(false, err);
		}
  }

	async login() {
		this.#render(true);
		return new Promise(async (resolve, reject) => {
			if (this.ii == null) try {
				this.ii = await AuthClient.create();
			} catch (cause) {
				const err = new Error('login client', { cause });
				this.#render(false, err);
				return reject(err);
			}
			const self = this;
			async function onSuccess() {
				try {
					await self.#authed();
					self.#render(false);
					resolve();
				} catch (cause) {
					const err = new Error('login', { cause });
					this.#render(false, err);
					reject(err);
				}
			}
			try {
				if (await this.ii.isAuthenticated()) {
					onSuccess();
				} else this.ii.login({
					maxTimeToLive: DAYS_30_NANOS,
					identityProvider,
					onSuccess,
				});
			} catch (cause) {
				const err = new Error('is auth', { cause });
				this.#render(false, err);
				reject(err);
			}
		});
	}

	async #authed() {
		return new Promise(async (resolve, reject) => {
			try {
				const identity = await this.ii.getIdentity();
				this.agent = await HttpAgent.create({ identity });
				this.principal = await identity.getPrincipal();
				this.accountid = AccountIdentifier.fromPrincipal({ principal: this.principal }).toHex();
				console.log('p\n', this.principal.toText(), '\na\n', this.accountid);
				resolve();
			} catch (err) {
				reject(err);
			}
		});
	}

	async logout() {
		this.#render(true);
		return new Promise(async (resolve, reject) => {
			try {
				await this.ii.logout();
				this.ii = null;
				this.agent = null;
				this.principal = null;
				this.accountid = null;
				this.#render();
				resolve();
			} catch (cause) {
				const err = new Error('logout', { cause });
				this.#render(false, err)
				reject(err);
			}
		});
	}
}

export default InternetIdentity;