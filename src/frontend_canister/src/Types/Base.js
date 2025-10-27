class Base {
	initial = 0n;
	locked = 0n;
	filled = 0n;

	constructor({ initial, locked, filled } = { initial: 0n, locked : 0n, filled: 0n }){
		this.initial = initial;
		this.locked = locked;
		this.filled = filled;
	}

	add({ initial, locked, filled } = { initial: 0n, locked : 0n, filled: 0n }) {
		this.initial += initial;
		this.locked += locked;
		this.filled += filled;
	}

	sub({ initial, locked, filled } = { initial: 0n, locked : 0n, filled: 0n }) {
		this.initial += initial;
		this.locked += locked;
		this.filled += filled;
	}

	mul(n = 0n) {
		this.initial *= n;
		this.locked *= n;
		this.filled *= n;
	}
}
export default Base