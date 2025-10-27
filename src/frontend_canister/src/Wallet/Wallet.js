import InternetIdentity from "./InternetIdentity";

class Wallet {
  ii = null;
  // plug

  constructor() {
		this.ii = new InternetIdentity();
  }

  get() {
    this.ii;
  }
}

export default Wallet;