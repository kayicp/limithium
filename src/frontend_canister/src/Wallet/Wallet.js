import InternetIdentity from "./InternetIdentity";

class Wallet {
  ii = null;
  // plug

  constructor() {
		this.ii = new InternetIdentity();
  }

  get() {
    return this.ii;
  }
}

export default Wallet;