import W "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Account "../util/motoko/ICRC-1/Account";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var block_id = 0;

  var meta : Value.Metadata = RBTree.empty();

  var owners = RBTree.empty<Principal, W.User>();
  var owner_ids = RBTree.empty<Nat, Principal>();
  var subaccount_maps = RBTree.empty<Blob, W.SubaccountMap>();
  var subaccount_ids = RBTree.empty<Nat, Blob>();

  var deposit_icrc2_dedupes : W.ICRCDedupes = RBTree.empty();
  var withdraw_icrc1_dedupes : W.ICRCDedupes = RBTree.empty();

  public shared ({ caller }) func wallet_deposit_icrc2(arg : W.ICRCTokenArg) : async W.DepositRes {
    let user = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user)) return Error.text("Caller account is not valid");

    let token_array = Value.getArray(meta, W.TOKENS, []);
    let arg_subaccount = Account.denull(arg.subaccount);

    #Ok 1;
  };
  // todo: deposit/withdraw icrc1_transfer
  // todo: deposit/withdraw native btc/eth

  public shared ({ caller }) func wallet_withdraw_icrc1(arg : W.ICRCTokenArg) : async W.WithdrawRes {
    #Ok 1;
  };

  public shared ({ caller }) func wallet_lock({
    token : Principal;
    amount : Nat;
  }) : async Nat {
    1;
  };
};
