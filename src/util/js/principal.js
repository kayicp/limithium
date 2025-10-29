import { Principal } from '@dfinity/principal';

Principal.prototype.toString = function () {
	return this.toText();
}
Principal.prototype.toJSON = function () {
	return this.toString();
}

export default Principal;
