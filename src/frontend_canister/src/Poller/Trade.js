class Trade {
	id = null;
	sell_id = null;
	sell_base = null;
	sell_fee_quote = null;
	sell_exec = null;
	sell_fee_exec = null;
	buy_id = null;
	buy_quote = null;
	buy_fee_base = null;
	buy_exec = null;
	buy_fee_exec = null;
	created_at = null;
	block = null;

	constructor(id) {
		this.id = id;
	}
}
export default Trade;