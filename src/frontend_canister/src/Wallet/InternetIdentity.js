import { AuthClient } from "@dfinity/auth-client";
import { HttpAgent } from '@dfinity/agent';
import Principal from '../../../util/js/principal';
import { AccountIdentifier } from '@dfinity/ledger-icp'
import Constant from "./Constants";

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
	pubsub = null;

  constructor(pubsub) {
		this.pubsub = pubsub;
		this.#init();
  }

  async #init() {
		this.pubsub.emit(Constant.LOGIN_BUSY);
    if (this.ii == null) try {
      this.ii = await AuthClient.create();
    } catch (err) {
			return this.pubsub.emit(Constant.CLIENT_ERR, err);
    }
    try {
      if (await this.ii.isAuthenticated()) {
				// proceed to #authed
			} else return this.pubsub.emit(Constant.ANON_OK);
    } catch (err) {
			return this.pubsub.emit(Constant.IS_AUTH_ERR, err);
    }
		try {
			await this.#authed();
			this.pubsub.emit(Constant.LOGIN_OK);
		} catch (err) {
			this.pubsub.emit(Constant.LOGIN_ERR, err);
		}
  }

	async login() {
		this.pubsub.emit(Constant.LOGIN_BUSY);
		return new Promise(async (resolve, reject) => {
			if (this.ii == null) try {
				this.ii = await AuthClient.create();
			} catch (err) {
				this.pubsub.emit(Constant.CLIENT_ERR, err);
				return reject(err);
			}
			const self = this;
			async function onSuccess() {
				try {
					await self.#authed();
					self.pubsub.emit(Constant.LOGIN_OK);
					resolve();
				} catch (err) {
					self.emit(Constant.LOGIN_ERR, err);
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
			} catch (err) {
				this.pubsub.emit(Constant.IS_AUTH_ERR, err);
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
				resolve();
			} catch (err) {
				reject(err);
			}
		});
	}

	async logout() {
		this.pubsub.emit(Constant.LOGOUT_BUSY);
		return new Promise(async (resolve, reject) => {
			try {
				await this.ii.logout();
				this.ii = null;
				this.agent = null;
				this.principal = null;
				this.accountid = null;
				this.pubsub.emit(Constant.LOGOUT_OK);
				resolve();
			} catch (err) {
				this.pubsub.emit(Constant.LOGOUT_ERR, err);
				reject(err);
			}
		});
	}
}

export default InternetIdentity;