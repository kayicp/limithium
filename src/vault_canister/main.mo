import V "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import ICRC1L "../icrc1_canister/ICRC1";
import ICRC1T "../icrc1_canister/Types";
import ICRC1 "../icrc1_canister/main";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import Principal "mo:base/Principal";
import Nat64 "mo:base/Nat64";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Time64 "../util/motoko/Time64";
import Vault "Vault";
import Result "../util/motoko/Result";
import Subaccount "../util/motoko/Subaccount";

// todo: lets not use user/subacc id mapping, store everything as-is

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var block_id = 0;

  var meta : Value.Metadata = RBTree.empty();
  var users : V.Users = RBTree.empty();
  var icrc1s = RBTree.empty<Principal, V.ICRC1Token>();
  var executors = RBTree.empty<Principal, ()>();
  var blocks = RBTree.empty<Nat, Value.Type>();

  var deposit_icrc2_dedupes : V.ICRCDedupes = RBTree.empty();
  var withdraw_icrc1_dedupes : V.ICRCDedupes = RBTree.empty();

  public shared ({ caller }) func vault_deposit_icrc2(arg : V.ICRC1TokenArg) : async V.DepositRes {
    if (not Value.getBool(meta, V.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getICRC1(arg.canister_id)) {
      case (?found) found;
      case _ return Error.text("Unsupported token");
    };
    if (arg.amount < token.min_deposit) return #Err(#AmountTooLow { minimum_amount = token.min_deposit });
    switch (arg.fee) {
      case (?defined) if (defined != token.deposit_fee) return #Err(#BadFee { expected_fee = token.deposit_fee });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let self_acct = { owner = Principal.fromActor(Self); subaccount = null };
    let (fee_res, balance_res, allowance_res) = (token_canister.icrc1_fee(), token_canister.icrc1_balance_of(user_acct), token_canister.icrc2_allowance({ account = user_acct; spender = self_acct }));
    let (fee, balance, approval) = (await fee_res, await balance_res, await allowance_res);
    let xfer_amount = arg.amount + token.deposit_fee;
    if (balance < xfer_amount + fee) return #Err(#InsufficientBalance { balance });
    if (approval.allowance < xfer_amount) return #Err(#InsufficientAllowance approval);

    let now = Time64.nanos();
    switch (checkIdempotency(caller, #DepositICRC arg, now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let xfer_arg = {
      from = user_acct;
      to = self_acct;
      spender_subaccount = self_acct.subaccount;
      fee = ?fee;
      amount = xfer_amount;
      memo = null;
      created_at_time = null;
    };
    let xfer_id = switch (await token_canister.icrc2_transfer_from(xfer_arg)) {
      case (#Ok ok) ok;
      case (#Err err) return #Err(#TransferFailed err);
    };
    var user = getUser(caller);
    let arg_subacc = Subaccount.get(arg.subaccount);
    var subacc = Vault.getSubaccount(user, arg_subacc);
    var bal = Vault.getICRCBalance(subacc, arg.canister_id);
    bal := { bal with unlocked = bal.unlocked + arg.amount };
    subacc := Vault.saveICRCBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    user := saveUser(caller, user);

    // todo: take fee, but skip since fee is zero
    // todo: blockify
    // todo: save dedupe
    #Ok 1;
  };
  // todo: deposit/withdraw icrc1_transfer
  // todo: deposit/withdraw native btc/eth

  public shared ({ caller }) func vault_withdraw_icrc1(arg : V.ICRC1TokenArg) : async V.WithdrawRes {
    if (not Value.getBool(meta, V.AVAILABLE, true)) return Error.text("Unavailable");

    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getICRC1(arg.canister_id)) {
      case (?found) found;
      case _ return Error.text("Unsupported token");
    };
    let xfer_fee = await token_canister.icrc1_fee();
    if (token.withdrawal_fee <= xfer_fee) return Error.text("Withdrawal fee must be larger than transfer fee");

    var user = getUser(caller);
    let arg_subacc = Subaccount.get(arg.subaccount);
    var subacc = Vault.getSubaccount(user, arg_subacc);
    var bal = Vault.getICRCBalance(subacc, arg.canister_id);
    let to_lock = arg.amount + token.withdrawal_fee;
    if (bal.unlocked < to_lock) return #Err(#InsufficientBalance { balance = bal.unlocked });

    switch (arg.fee) {
      case (?defined) if (defined != token.withdrawal_fee) return #Err(#BadFee { expected_fee = token.withdrawal_fee });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    let now = Time64.nanos();
    switch (checkIdempotency(caller, #WithdrawICRC arg, now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    bal := {
      unlocked = bal.unlocked - to_lock;
      locked = bal.locked + to_lock;
    }; // lock to prevent double spending
    subacc := Vault.saveICRCBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    user := saveUser(caller, user);
    let xfer_arg = {
      amount = arg.amount;
      to = user_acct;
      fee = ?xfer_fee;
      memo = null;
      from_subaccount = null;
      created_at_time = null;
    };
    let xfer_res = await token_canister.icrc1_transfer(xfer_arg);
    user := getUser(caller);
    subacc := Vault.getSubaccount(user, arg_subacc);
    bal := Vault.getICRCBalance(subacc, arg.canister_id);
    bal := { bal with locked = bal.locked - to_lock }; // release lock
    switch xfer_res {
      case (#Err _) bal := { bal with unlocked = bal.unlocked + to_lock }; // recover fund
      case _ {};
    };
    subacc := Vault.saveICRCBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    user := saveUser(caller, user);
    let xfer_id = switch xfer_res {
      case (#Err err) return #Err(#TransferFailed err);
      case (#Ok ok) ok;
    };

    let this_canister = Principal.fromActor(Self);
    let canister_subaccount = Subaccount.get(null);
    user := getUser(this_canister); // give fee to canister
    subacc := Vault.getSubaccount(user, canister_subaccount);
    bal := Vault.getICRCBalance(subacc, arg.canister_id);
    let canister_take = token.withdrawal_fee - xfer_fee;
    bal := { bal with unlocked = bal.unlocked + canister_take };
    subacc := Vault.saveICRCBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, canister_subaccount, subacc);
    user := saveUser(this_canister, user);

    // todo: blockify
    // todo: save dedupe
    #Ok 1;
  };

  public shared ({ caller }) func vault_execute(instructions : [V.Instruction]) : async V.ExecuteRes {
    if (not RBTree.has(executors, Principal.compare, caller)) return Error.text("Caller is not an executor");
    if (instructions.size() == 0) return Error.text("Instructions must not be empty");

    var lusers : V.Users = RBTree.empty();

    func getAccount(acc : ICRC1T.Account) : V.UserData {
      let user = switch (RBTree.get(lusers, Principal.compare, acc.owner)) {
        case (?found) found;
        case _ switch (RBTree.get(users, Principal.compare, acc.owner)) {
          case (?found) found;
          case _ ({
            last_activity = 0 : Nat64;
            subaccs = RBTree.empty();
          });
        };
      };
      let subacc = Subaccount.get(acc.subaccount);
      let subacc_data = Vault.getSubaccount(user, subacc);
      { acc with user; subacc; subacc_data };
    };
    var a = getAccount(instructions[0].account);
    var asset = instructions[0].asset;
    var b = Vault.getBalance(asset, a.subacc_data);
    func reserve<T>(t : T) : T {
      a := {
        a with subacc_data = Vault.saveBalance(asset, a.subacc_data, b);
        user = Vault.saveSubaccount(a.user, a.subacc, a.subacc_data);
      };
      lusers := RBTree.insert(lusers, Principal.compare, a.owner, a.user);
      t;
    };
    func execute(index : Nat) : V.ExecuteRes = if (instructions[index].amount > 0) switch (instructions[index].action) {
      case (#Lock) if (b.unlocked < instructions[index].amount) return #Err(#InsufficientBalance { index; balance = b.unlocked }) else {
        b := Vault.decUnlock(b, instructions[index].amount);
        b := Vault.incLock(b, instructions[index].amount);
        reserve(#Ok index);
      };
      case (#Unlock) if (b.locked < instructions[index].amount) return #Err(#InsufficientBalance { index; balance = b.locked }) else {
        b := Vault.decLock(b, instructions[index].amount);
        b := Vault.incUnlock(b, instructions[index].amount);
        reserve(#Ok index);
      };
      case (#Transfer action) {
        if (b.unlocked < instructions[index].amount) return #Err(#InsufficientBalance { index; balance = b.unlocked });
        if (ICRC1L.equalAccount(instructions[index].account, action.to)) return #Err(#InvalidTransfer { index });
        b := Vault.decUnlock(b, instructions[index].amount);
        reserve();

        a := getAccount(action.to);
        b := Vault.getBalance(asset, a.subacc_data);
        b := Vault.incUnlock(b, instructions[index].amount);
        reserve(#Ok index);
      };
    } else return #Err(#ZeroAmount { index });
    switch (execute(0)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    for (i in Iter.range(1, instructions.size() - 1)) {
      a := getAccount(instructions[i].account);
      asset := instructions[i].asset;
      b := Vault.getBalance(asset, a.subacc_data);
      switch (execute(i)) {
        case (#Err err) return #Err err;
        case _ ();
      };
    };
    for ((k, v) in RBTree.entries(lusers)) users := RBTree.insert(users, Principal.compare, k, v);

    // todo: blockify
    #Ok 1;
  };

  func getUser(p : Principal) : V.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({
      last_activity = 0;
      subaccs = RBTree.empty();
    });
  };
  func saveUser(p : Principal, u : V.User) : V.User {
    users := RBTree.insert(users, Principal.compare, p, u);
    u;
  };
  func checkMemo(m : ?Blob) : Result.Type<(), Error.Generic> = switch m {
    case (?defined) {
      var min_memo_size = Value.getNat(meta, V.MIN_MEMO, 1);
      if (min_memo_size < 1) {
        min_memo_size := 1;
        meta := Value.setNat(meta, V.MIN_MEMO, ?min_memo_size);
      };
      if (defined.size() < min_memo_size) return Error.text("Memo size must be larger than " # debug_show min_memo_size);

      var max_memo_size = Value.getNat(meta, V.MAX_MEMO, 1);
      if (max_memo_size < min_memo_size) {
        max_memo_size := min_memo_size;
        meta := Value.setNat(meta, V.MAX_MEMO, ?max_memo_size);
      };
      if (defined.size() > max_memo_size) return Error.text("Memo size must be smaller than " # debug_show max_memo_size);
      #Ok;
    };
    case _ #Ok;
  };
  func checkIdempotency(caller : Principal, opr : V.ArgType, now : Nat64, created_at_time : ?Nat64) : Result.Type<(), { #CreatedInFuture : { ledger_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    var tx_window = Nat64.fromNat(Value.getNat(meta, V.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, V.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, V.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, V.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    switch (created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { ledger_time = now });
        let (map, comparer, arg) = switch opr {
          case (#DepositICRC depo) (deposit_icrc2_dedupes, Vault.dedupeICRC, depo);
          case (#WithdrawICRC draw) (withdraw_icrc1_dedupes, Vault.dedupeICRC, draw);
        };
        switch (RBTree.get(map, comparer, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };
  func getICRC1(p : Principal) : ?(ICRC1.Canister, V.ICRC1Token) = switch (RBTree.get(icrc1s, Principal.compare, p)) {
    case (?found) ?(actor (Principal.toText(p)), found);
    case _ null;
  };

  public shared ({ caller }) func vault_enlist_icrc1({
    canister_id : Principal;
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    if (min_deposit <= deposit_fee) return Error.text("min_deposit must be larger than deposit_fee");

    let token = actor (Principal.toText(canister_id)) : ICRC1.Canister;
    let transfer_fee = await token.icrc1_fee();
    if (withdrawal_fee <= transfer_fee) return Error.text("withdrawal_fee must be larger than transfer fee (" # debug_show transfer_fee # ")");

    if (min_deposit <= withdrawal_fee) return Error.text("min_deposit must be larger than withdrawal_fee");

    let config = switch (RBTree.get(icrc1s, Principal.compare, canister_id)) {
      case (?found) ({ found with min_deposit; deposit_fee; withdrawal_fee });
      case _ ({ min_deposit; deposit_fee; withdrawal_fee });
    };
    icrc1s := RBTree.insert(icrc1s, Principal.compare, canister_id, config);
    #Ok;
  };

  public shared ({ caller }) func vault_delist_icrc1({
    canister_id : Principal;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    icrc1s := RBTree.delete(icrc1s, Principal.compare, canister_id);
    #Ok;
  };

  public shared ({ caller }) func vault_approve_executor({
    canister_id : Principal;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    executors := RBTree.insert(executors, Principal.compare, canister_id, ());
    #Ok;
  };

  public shared query func vault_is_executor(p : Principal) : async Bool = async RBTree.has(executors, Principal.compare, p);

  public shared ({ caller }) func vault_revoke_executor({
    canister_id : Principal;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    executors := RBTree.delete(executors, Principal.compare, canister_id);
    #Ok;
  };
};
