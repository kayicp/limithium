import { Principal } from '@dfinity/principal';

Principal.prototype.toString = function () {
	return this.toText();
}
Principal.prototype.toJSON = function () {
	return this.toString();
}

export function shortPrincipal(p, show_middle = false) {
  if (p.isAnonymous()) return "Anonymous";
  let str = p.toText();
  let splitted = str.split('-');
  if (show_middle) {
    return splitted.length <= 3? str : `${splitted[0]}-...-${splitted[Math.floor(splitted.length / 2)]}-...-${splitted[splitted.length - 1]}`;
  } else return splitted.length <= 2? str : `${splitted[0]}-...-${splitted[splitted.length - 1]}`;
}
