export function nano2date(ns) {
	const ms = Number(ns / 1000000n); 
	return new Date(ms);
}