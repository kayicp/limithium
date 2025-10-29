import { AuthClient } from "@dfinity/auth-client";
import { HttpAgent } from '@dfinity/agent';
import { Principal } from '@dfinity/principal';
import { AccountIdentifier } from '@dfinity/ledger-icp'

const network = process.env.DFX_NETWORK;
const identityProvider =
  network === 'ic'
    ? 'https://identity.ic0.app' // Mainnet
    : 'http://rdmx6-jaaaa-aaaaa-aaadq-cai.localhost:5000'; // Local

const DAYS_30_NANOS = BigInt(30 * 24 * 60 * 60 * 1000 * 1000 * 1000);

class InternetIdentity {
  ii = null;
	agent = null;
	principal = null;
	accountid = null;

  constructor() {
		this.#init();
  }

  async #init() {
    if (this.ii == null) try {
      this.ii = await AuthClient.create();
    } catch (err) {
      return console.error('II init create', err);
    }
    try {
      if (await this.ii.isAuthenticated()) {
				await this.#authed();
			} else console.log('II init no auth');
    } catch (err) {
			console.error('II try init err', err);
    }
  }

	async login() {
		return new Promise(async (resolve, reject) => {
			if (this.ii == null) try {
				this.ii = await AuthClient.create();
			} catch (e) {
				reject(e);
			}
			try {
				if (await this.ii.isAuthenticated()) {
					await this.#authed();
					resolve();
				} else this.ii.login({
					maxTimeToLive: DAYS_30_NANOS,
					identityProvider,
					onSuccess: async () => {
						try {
							await this.#authed();
							resolve();
						} catch (e) {
							reject(e)
						}
					},
				});
			} catch (e) {
				reject(e);
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
				resolve();
			} catch (e) {
				reject(e);
			}
		});
	}

	async logout() {
		return new Promise(async (resolve, reject) => {
			try {
				await this.ii.logout();
				this.ii = null;
				this.agent = null;
				this.principal = null;
				this.accountid = null;
				resolve();
			} catch (e) {
				reject(e);
			}
		});
	}
}

export default InternetIdentity;