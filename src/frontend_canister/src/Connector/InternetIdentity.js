import { AuthClient } from "@dfinity/auth-client";
import { HttpAgent } from '@dfinity/agent';
import { Principal } from '@dfinity/principal';
import { AccountIdentifier } from '@dfinity/ledger-icp'

class InternetIdentity {
  ii = null;
  busy = false;
	agent = null;
	principal = null;
	accountid = null;

  constructor() {
		this.#init();
  }

  async #init() {
		if (this.busy) return console.error('II is busy');
    this.busy = true;
    if (this.ii == null) try {
      this.ii = await AuthClient.create();
    } catch (err) {
      this.busy = false; 
      return console.error('II init create', err);
    }
    try {
      if (await this.ii.isAuthenticated()) return this.#authed(
				() => console.log('II init ok'), 
				(e) => console.error('II init err', e)
			); else console.log('II init no auth');
    } catch (err) {
			console.error('II try init err', err);
    }
		this.busy = false;
  }

	async login(identityProvider, ok, err) {
		if (this.busy) return err(Error('II is busy'));
		this.busy = true;
		if (this.ii == null) try {
			this.ii = await AuthClient.create();
		} catch (e) {
			this.busy = false;
			return err(e);
		}
		try {
			if (await this.ii.isAuthenticated()) {
				this.#authed(ok, err);
			} else this.ii.login({
				// 30 days in nanoseconds
        maxTimeToLive: BigInt(30 * 24 * 60 * 60 * 1000 * 1000 * 1000),
        identityProvider,
        onSuccess: async () => await this.#authed(ok, err),
			});
		} catch (e) {
			this.busy = false;
			err(e);
		}
	}

	async #authed(ok, err) {
		try {
			const identity = await this.ii.getIdentity();
			this.agent = await HttpAgent.create({ identity });
			this.principal = await identity.getPrincipal();
			this.accountid = AccountIdentifier.fromPrincipal({ principal: this.principal }).toHex();
			this.busy = false;
			ok();
		} catch (e) {
			this.busy = false;
			err(e);
		}
	}

	async logout(ok, err) {
		if (this.busy) return err(Error('II is busy'));
		this.busy = true;
		try {
			await this.ii.logout();
			this.ii = null;
			this.agent = null;
			this.principal = null;
			this.accountid = null;
			this.busy = false;
			ok();
		} catch (e) {
			this.busy = false;
			err(e);
		}
	}
}

export default InternetIdentity;