import O "Types";
import Value "../util/motoko/Value";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Error "../util/motoko/Error";
import Account "../util/motoko/ICRC-1/Account";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var meta : Value.Metadata = RBTree.empty();

  var order_id = 0;

  // public shared query func orderbook_buy_balances_of() : async [Nat] {
  //   []
  // };

  // public shared query func orderbook_sell_balances_of() : async [Nat] {
  //   []
  // };

  public shared ({ caller }) func orderbook_place(arg : O.PlaceArg) : async O.PlaceRes {
    // if (not Value.getBool(meta, O.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    if (arg.orders.size() == 0) return Error.text("Orders must not be empty");

    let lbuys = RBTree.empty<(price : Nat), {}>();
    for (o in arg.orders.vals()) {

    };
    #Ok([]);
  };

  public shared ({ caller }) func orderbook_cancel() : async () {

  };

  public shared ({ caller }) func orderbook_run() : async () {

  };
};
