import W "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Account "../util/motoko/ICRC-1/Account";
import ICRCToken "../util/motoko/ICRC-1/Types";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Nat64 "mo:base/Nat64";
import Time64 "../util/motoko/Time64";
import Wallet "Wallet";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var block_id = 0;

  var meta : Value.Metadata = RBTree.empty();

  var users : W.Users = RBTree.empty();
  var user_ids = RBTree.empty<Nat, Principal>();
  var subaccount_maps = RBTree.empty<Blob, W.SubaccountMap>();
  var subaccount_ids = RBTree.empty<Nat, Blob>();

  var deposit_icrc2_dedupes : W.ICRCDedupes = RBTree.empty();
  var withdraw_icrc1_dedupes : W.ICRCDedupes = RBTree.empty();

  var icrc2s = RBTree.empty<Principal, W.ICRCToken>();

  public shared ({ caller }) func wallet_deposit_icrc2(arg : W.ICRCTokenArg) : async W.DepositRes {
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    let (token, token_config) = switch (RBTree.get(icrc2s, Principal.compare, arg.token)) {
      case (?found) (ICRCToken.genActor(arg.token), found);
      case _ return Error.text("Unsupported token");
    };
    if (arg.amount < token_config.min_deposit) return #Err(#AmountTooLow { minimum_amount = token_config.min_deposit });
    switch (arg.fee) {
      case (?defined) if (defined != token_config.deposit_fee) return #Err(#BadFee { expected_fee = token_config.deposit_fee });
      case _ ();
    };
    switch (arg.memo) {
      case (?defined) {
        var min_memo_size = Value.getNat(meta, W.MIN_MEMO, 1);
        if (min_memo_size < 1) {
          min_memo_size := 1;
          meta := Value.setNat(meta, W.MIN_MEMO, ?min_memo_size);
        };
        if (defined.size() < min_memo_size) return Error.text("Memo size must be larger than " # debug_show min_memo_size);

        var max_memo_size = Value.getNat(meta, W.MAX_MEMO, 1);
        if (max_memo_size < min_memo_size) {
          max_memo_size := min_memo_size;
          meta := Value.setNat(meta, W.MAX_MEMO, ?max_memo_size);
        };
        if (defined.size() > max_memo_size) return Error.text("Memo size must be smaller than " # debug_show max_memo_size);
      };
      case _ ();
    };
    let self_acct = { owner = Principal.fromActor(Self); subaccount = null };
    let (fee_res, balance_res, allowance_res) = (token.icrc1_fee(), token.icrc1_balance_of(user_acct), token.icrc2_allowance({ account = user_acct; spender = self_acct }));
    let (fee, balance, approval) = (await fee_res, await balance_res, await allowance_res);
    let minimum_balance = arg.amount + fee;
    if (balance < minimum_balance) return #Err(#InsufficientBalance { balance });
    if (approval.allowance < minimum_balance) return #Err(#InsufficientAllowance approval);

    let now = Time64.nanos();
    var tx_window = Nat64.fromNat(Value.getNat(meta, W.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, W.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, W.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, W.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    switch (arg.created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { ledger_time = now });
        switch (RBTree.get(deposit_icrc2_dedupes, W.dedupeICRC, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ ();
        };
      };
      case _ ();
    };

    var user = getUser(caller);
    let arg_subaccount = Account.denull(arg.subaccount);
    var subacc = getSubaccount(user, arg_subaccount);

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

  func getUser(p : Principal) : W.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({
      id = Wallet.recycleId(user_ids);
      last_activity = 0;
      subaccounts = RBTree.empty();
    });
  };
  func getSubaccount(u : W.User, sub : Blob) {
    let;
  };

  public shared ({ caller }) func wallet_enlist_icrc2({
    canister_id : Principal;
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  }) : async W.GenericRes {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    if (min_deposit <= deposit_fee) return Error.text("min_deposit must be larger than deposit_fee");

    let token = ICRCToken.genActor(canister_id);
    let transfer_fee = await token.icrc1_fee();
    if (withdrawal_fee <= transfer_fee) return Error.text("withdrawal_fee must be larger than transfer fee (" # debug_show transfer_fee # ")");

    if (min_deposit <= withdrawal_fee) return Error.text("min_deposit must be larger than withdrawal_fee");

    icrc2s := RBTree.insert(icrc2s, Principal.compare, canister_id, { min_deposit; deposit_fee; withdrawal_fee });

    #Ok;
  };

  public shared ({ caller }) func wallet_delist_icrc2({
    canister_id : Principal;
  }) : async W.GenericRes {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    icrc2s := RBTree.delete(icrc2s, Principal.compare, canister_id);
    #Ok;
  };
};
