import W "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Account "../util/motoko/ICRC-1/Account";
import ICRC2Token "../util/motoko/ICRC-1/Types";
import Error "../util/motoko/Error";
import Value "../util/motoko/Value";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Nat64 "mo:base/Nat64";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
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

  var icrc2s = RBTree.empty<Principal, W.ICRC2Token>();
  var icrc2_ids = RBTree.empty<Nat, Principal>();

  var books = RBTree.empty<Principal, ()>();

  var deposit_icrc2_dedupes : W.ICRCDedupes = RBTree.empty();
  var withdraw_icrc1_dedupes : W.ICRCDedupes = RBTree.empty();

  public shared ({ caller }) func wallet_deposit_icrc2(arg : W.ICRC2TokenArg) : async W.DepositRes {
    if (not Value.getBool(meta, W.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getICRC2(arg.canister_id)) {
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
    let arg_subacc = Account.denull(arg.subaccount);
    var subacc = getSubaccount(user, arg_subacc);
    var bal = Wallet.getICRCBalance(subacc.data, token.id);
    bal := { bal with unlocked = bal.unlocked + arg.amount };
    subacc := {
      subacc with data = Wallet.saveICRCBalance(subacc.data, token.id, bal)
    };
    user := saveSubaccount(user, arg_subacc, subacc.map, subacc.data);
    user := saveUser(caller, user);

    // todo: take fee, but later since fee is zero
    // todo: blockify
    #Ok 1;
  };
  // todo: deposit/withdraw icrc1_transfer
  // todo: deposit/withdraw native btc/eth

  public shared ({ caller }) func wallet_withdraw_icrc1(arg : W.ICRC2TokenArg) : async W.WithdrawRes {
    if (not Value.getBool(meta, W.AVAILABLE, true)) return Error.text("Unavailable");

    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not Account.validate(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getICRC2(arg.canister_id)) {
      case (?found) found;
      case _ return Error.text("Unsupported token");
    };
    let xfer_fee = await token_canister.icrc1_fee();
    if (token.withdrawal_fee <= xfer_fee) return Error.text("Withdrawal fee must be larger than transfer fee");

    var user = getUser(caller);
    let arg_subacc = Account.denull(arg.subaccount);
    var subacc = getSubaccount(user, arg_subacc);
    var bal = Wallet.getICRCBalance(subacc.data, token.id);
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
    subacc := {
      subacc with data = Wallet.saveICRCBalance(subacc.data, token.id, bal)
    };
    user := saveSubaccount(user, arg_subacc, subacc.map, subacc.data);
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
    subacc := getSubaccount(user, arg_subacc);
    bal := Wallet.getICRCBalance(subacc.data, token.id);
    bal := { bal with locked = bal.locked - to_lock }; // release lock
    switch xfer_res {
      case (#Err _) bal := { bal with unlocked = bal.unlocked + to_lock }; // recover fund
      case _ {};
    };
    subacc := {
      subacc with data = Wallet.saveICRCBalance(subacc.data, token.id, bal)
    };
    user := saveSubaccount(user, arg_subacc, subacc.map, subacc.data);
    user := saveUser(caller, user);
    let xfer_id = switch xfer_res {
      case (#Err err) return #Err(#TransferFailed err);
      case (#Ok ok) ok;
    };

    let this_canister = Principal.fromActor(Self);
    let canister_subaccount = Account.denull(null);
    user := getUser(this_canister); // give fee to canister
    subacc := getSubaccount(user, canister_subaccount);
    bal := Wallet.getICRCBalance(subacc.data, token.id);
    let canister_take = token.withdrawal_fee - xfer_fee;
    bal := { bal with unlocked = bal.unlocked + canister_take };
    subacc := {
      subacc with data = Wallet.saveICRCBalance(subacc.data, token.id, bal)
    };
    user := saveSubaccount(user, canister_subaccount, subacc.map, subacc.data);
    user := saveUser(this_canister, user);

    // todo: blockify
    #Ok 1;
  };

  public shared ({ caller }) func wallet_execute(instructions : [W.Instruction]) : async W.ExecuteRes {
    if (not RBTree.has(books, Principal.compare, caller)) return Error.text("Caller is not an orderbook canister");
    if (instructions.size() == 0) return Error.text("Instructions must not be empty");

    var lusers : W.Users = RBTree.empty();
    var luser_ids = RBTree.empty<Nat, Principal>();
    var lsubacc_maps = RBTree.empty<Blob, W.SubaccountMap>();
    var lsubacc_ids = RBTree.empty<Nat, Blob>();

    func getAccount(acc : Account.Pair) : W.UserData {
      let user = switch (RBTree.get(lusers, Principal.compare, acc.owner)) {
        case (?found) found;
        case _ switch (RBTree.get(users, Principal.compare, acc.owner)) {
          case (?found) found;
          case _ ({
            id = Nat.max(Wallet.recycleId(user_ids), Wallet.recycleId(luser_ids));
            last_activity = 0 : Nat64;
            subaccounts = RBTree.empty();
          });
        };
      };
      let arg_subacc = Account.denull(acc.subaccount);
      var subacc_map = switch (RBTree.get(lsubacc_maps, Blob.compare, arg_subacc)) {
        case (?found) found;
        case _ switch (RBTree.get(subaccount_maps, Blob.compare, arg_subacc)) {
          case (?found) found;
          case _ ({
            id = Nat.max(Wallet.recycleId(subaccount_ids), Wallet.recycleId(lsubacc_ids));
            owners = RBTree.empty();
          });
        };
      };
      subacc_map := {
        subacc_map with owners = RBTree.insert(subacc_map.owners, Nat.compare, user.id, ())
      };
      let subacc_data = Wallet.getSubaccount(user, subacc_map.id);
      { user; arg_subacc; subacc_map; subacc_data };
    };
    var a = getAccount(instructions[0].account);
    func reserve<T>(t : T) : T {
      // todo: finish this
      t;
    };
    func execute(index : Nat) : W.ExecuteRes {
      let asset_key = switch (instructions[index].asset) {
        case (#ICRC2 token) switch (getICRC2(token.canister_id)) {
          case (?(_, { id })) #ICRC2 id;
          case _ return #Err(#UnlistedAsset { index });
        };
      };
      var b = Wallet.getBalance(asset_key, a.subacc_data);
      switch (instructions[index].action) {
        case (#Lock action) if (b.unlocked < action.amount) return #Err(#InsufficientBalance { index; balance = b.unlocked }) else {
          b := Wallet.decUnlock(b, action.amount);
          b := Wallet.incLock(b, action.amount);
          reserve(#Ok index);
        };
        case (#Unlock action) if (b.locked < action.amount) return #Err(#InsufficientBalance { index; balance = b.locked }) else {
          b := Wallet.decLock(b, action.amount);
          b := Wallet.incUnlock(b, action.amount);
          reserve(#Ok index);
        };
        case (#Transfer action) {
          if (b.unlocked < action.amount) return #Err(#InsufficientBalance { index; balance = b.unlocked });
          if (Account.equal(instructions[index].account, action.to)) return #Err(#InvalidTransfer { index });
          b := Wallet.decUnlock(b, action.amount);
          reserve();

          a := getAccount(action.to);
          b := Wallet.getBalance(asset_key, a.subacc_data);
          b := Wallet.incUnlock(b, action.amount);
          reserve(#Ok index);
        };
      };
    };
    switch (execute(0)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    for (i in Iter.range(1, instructions.size() - 1)) {
      a := getAccount(instructions[i].account);
      switch (execute(i)) {
        case (#Err err) return #Err err;
        case _ ();
      };
    };
    // todo: commit all reserves
    // todo: blockify
    #Ok 1;
  };

  func getUser(p : Principal) : W.User = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ ({
      id = Wallet.recycleId(user_ids);
      last_activity = 0;
      subaccounts = RBTree.empty();
    });
  };
  func saveUser(p : Principal, u : W.User) : W.User {
    users := RBTree.insert(users, Principal.compare, p, u);
    user_ids := RBTree.insert(user_ids, Nat.compare, u.id, p);
    u;
  };
  func getSubaccount(u : W.User, sub : Blob) : {
    map : W.SubaccountMap;
    data : W.Subaccount;
  } {
    let map = switch (RBTree.get(subaccount_maps, Blob.compare, sub)) {
      case (?found) found;
      case _ ({
        id = Wallet.recycleId(subaccount_ids);
        owners = RBTree.empty();
      });
    };
    let owners = RBTree.insert(map.owners, Nat.compare, u.id, ());
    { map = { map with owners }; data = Wallet.getSubaccount(u, map.id) };
  };
  func saveSubaccount(u : W.User, sub : Blob, map : W.SubaccountMap, data : W.Subaccount) : W.User {
    subaccount_maps := RBTree.insert(subaccount_maps, Blob.compare, sub, map);
    subaccount_ids := RBTree.insert(subaccount_ids, Nat.compare, map.id, sub);
    Wallet.saveSubaccount(u, map.id, data);
  };
  func checkMemo(m : ?Blob) : W.GenericRes = switch m {
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
      #Ok;
    };
    case _ #Ok;
  };
  func checkIdempotency(caller : Principal, opr : W.ArgType, now : Nat64, created_at_time : ?Nat64) : W.IdempotentRes {
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
    switch (created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { ledger_time = now });
        let (map, comparer, arg) = switch opr {
          case (#DepositICRC depo) (deposit_icrc2_dedupes, W.dedupeICRC, depo);
          case (#WithdrawICRC draw) (withdraw_icrc1_dedupes, W.dedupeICRC, draw);
        };
        switch (RBTree.get(map, comparer, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };
  func getICRC2(p : Principal) : ?(ICRC2Token.Actor, W.ICRC2Token) = switch (RBTree.get(icrc2s, Principal.compare, p)) {
    case (?found) ?(ICRC2Token.genActor(p), found);
    case _ null;
  };

  public shared ({ caller }) func wallet_enlist_icrc2({
    canister_id : Principal;
    min_deposit : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  }) : async W.GenericRes {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    if (min_deposit <= deposit_fee) return Error.text("min_deposit must be larger than deposit_fee");

    let token = ICRC2Token.genActor(canister_id);
    let transfer_fee = await token.icrc1_fee();
    if (withdrawal_fee <= transfer_fee) return Error.text("withdrawal_fee must be larger than transfer fee (" # debug_show transfer_fee # ")");

    if (min_deposit <= withdrawal_fee) return Error.text("min_deposit must be larger than withdrawal_fee");

    let config = switch (RBTree.get(icrc2s, Principal.compare, canister_id)) {
      case (?found) ({ found with min_deposit; deposit_fee; withdrawal_fee });
      case _ {
        let id = Wallet.recycleId(icrc2_ids);
        icrc2_ids := RBTree.insert(icrc2_ids, Nat.compare, id, canister_id);
        { id; min_deposit; deposit_fee; withdrawal_fee };
      };
    };
    icrc2s := RBTree.insert(icrc2s, Principal.compare, canister_id, config);
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
