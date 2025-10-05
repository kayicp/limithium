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
import Buffer "mo:base/Buffer";
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
  var tokens = RBTree.empty<Principal, V.Token>();
  var executors = RBTree.empty<Principal, ()>();
  var blocks = RBTree.empty<Nat, Value.Type>();

  var deposit_dedupes : V.Dedupes = RBTree.empty();
  var withdraw_dedupes : V.Dedupes = RBTree.empty();

  public shared ({ caller }) func vault_deposit(arg : V.TokenArg) : async V.DepositRes {
    if (not Value.getBool(meta, V.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getToken(arg.canister_id)) {
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
    let xfer_and_fee = xfer_amount + fee;
    if (balance < xfer_and_fee) return #Err(#InsufficientBalance { balance });
    if (approval.allowance < xfer_and_fee) return #Err(#InsufficientAllowance approval);

    let now = Time64.nanos();
    switch (checkIdempotency(caller, #Deposit arg, now, arg.created_at_time)) {
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
    var user = Vault.getUser(users, caller);
    let arg_subacc = Subaccount.get(arg.subaccount);
    var subacc = Vault.getSubaccount(user, arg_subacc);
    var bal = Vault.getBalance(subacc, arg.canister_id);
    bal := Vault.incUnlock(bal, arg.amount);
    subacc := Vault.saveBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    users := Vault.saveUser(users, caller, user);

    // todo: take fee, but skip since fee is zero
    // todo: blockify
    // todo: save dedupe
    #Ok 1;
  };
  // todo: deposit via icrc1_transfer

  public shared ({ caller }) func vault_withdraw(arg : V.TokenArg) : async V.WithdrawRes {
    if (not Value.getBool(meta, V.AVAILABLE, true)) return Error.text("Unavailable");

    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getToken(arg.canister_id)) {
      case (?found) found;
      case _ return Error.text("Unsupported token");
    };
    let xfer_fee = await token_canister.icrc1_fee();
    if (token.withdrawal_fee <= xfer_fee) return Error.text("Withdrawal fee must be larger than transfer fee");

    var user = Vault.getUser(users, caller);
    let arg_subacc = Subaccount.get(arg.subaccount);
    var subacc = Vault.getSubaccount(user, arg_subacc);
    var bal = Vault.getBalance(subacc, arg.canister_id);
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
    switch (checkIdempotency(caller, #Withdraw arg, now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    bal := Vault.decUnlock(bal, to_lock); // lock to prevent double spending
    bal := Vault.incLock(bal, to_lock);
    subacc := Vault.saveBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    users := Vault.saveUser(users, caller, user);
    let xfer_arg = {
      amount = arg.amount;
      to = user_acct;
      fee = ?xfer_fee;
      memo = null;
      from_subaccount = null;
      created_at_time = null;
    };
    let xfer_res = await token_canister.icrc1_transfer(xfer_arg);
    user := Vault.getUser(users, caller);
    subacc := Vault.getSubaccount(user, arg_subacc);
    bal := Vault.getBalance(subacc, arg.canister_id);
    bal := Vault.decLock(bal, to_lock); // release lock
    switch xfer_res {
      case (#Err _) bal := Vault.incUnlock(bal, to_lock); // recover fund
      case _ ();
    };
    subacc := Vault.saveBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, arg_subacc, subacc);
    users := Vault.saveUser(users, caller, user);
    let xfer_id = switch xfer_res {
      case (#Err err) return #Err(#TransferFailed err);
      case (#Ok ok) ok;
    };
    let this_canister = Principal.fromActor(Self);
    let canister_subaccount = Subaccount.get(null);
    user := Vault.getUser(users, this_canister); // give fee to canister
    subacc := Vault.getSubaccount(user, canister_subaccount);
    bal := Vault.getBalance(subacc, arg.canister_id);
    bal := Vault.incUnlock(bal, token.withdrawal_fee - xfer_fee); // canister sponsored the xfer_fee
    subacc := Vault.saveBalance(subacc, arg.canister_id, bal);
    user := Vault.saveSubaccount(user, canister_subaccount, subacc);
    users := Vault.saveUser(users, this_canister, user);

    // todo: blockify
    // todo: save dedupe
    #Ok 1;
  };

  public shared ({ caller }) func vault_execute(instruction_blocks : [[V.Instruction]]) : async V.ExecuteRes {
    if (not RBTree.has(executors, Principal.compare, caller)) return Error.text("Caller is not an executor");
    if (instruction_blocks.size() == 0) return Error.text("Instruction blocks must not be empty");

    var lusers : V.Users = RBTree.empty();
    func getLuser(p : Principal) : V.User = switch (RBTree.get(lusers, Principal.compare, p)) {
      case (?found) found;
      case _ Vault.getUser(users, p);
    };
    var lblock_id = block_id;
    let res = Buffer.Buffer<Nat>(instruction_blocks.size());
    for (block_index in Iter.range(0, instruction_blocks.size() - 1)) {
      let instructions = instruction_blocks[block_index];
      if (instructions.size() == 0) return #Err(#EmptyInstructions { block_index });
      for (instruction_index in Iter.range(0, instructions.size() - 1)) {
        let i = instructions[instruction_index];
        if (i.amount == 0) return #Err(#ZeroAmount { block_index; instruction_index });
        if (not ICRC1L.validateAccount(i.account)) return #Err(#InvalidAccount { block_index; instruction_index });
        if (not RBTree.has(tokens, Principal.compare, i.token)) return #Err(#UnlistedToken { block_index; instruction_index });

        var user = getLuser(i.account.owner);
        var sub = Subaccount.get(i.account.subaccount);
        var subacc = Vault.getSubaccount(user, sub);
        var bal = Vault.getBalance(subacc, i.token);
        switch (i.action) {
          case (#Lock) {
            if (bal.unlocked < i.amount) return #Err(#InsufficientBalance { block_index; instruction_index; balance = bal.unlocked });
            bal := Vault.decUnlock(bal, i.amount);
            bal := Vault.incLock(bal, i.amount);
            subacc := Vault.saveBalance(subacc, i.token, bal);
            user := Vault.saveSubaccount(user, sub, subacc);
            lusers := Vault.saveUser(lusers, i.account.owner, user);
          };
          case (#Unlock) {
            if (bal.locked < i.amount) return #Err(#InsufficientBalance { block_index; instruction_index; balance = bal.locked });
            bal := Vault.decLock(bal, i.amount);
            bal := Vault.incUnlock(bal, i.amount);
            subacc := Vault.saveBalance(subacc, i.token, bal);
            user := Vault.saveSubaccount(user, sub, subacc);
            lusers := Vault.saveUser(lusers, i.account.owner, user);
          };
          case (#Transfer transfer) {
            if (bal.unlocked < i.amount) return #Err(#InsufficientBalance { block_index; instruction_index; balance = bal.unlocked });
            bal := Vault.decUnlock(bal, i.amount);
            subacc := Vault.saveBalance(subacc, i.token, bal);
            user := Vault.saveSubaccount(user, sub, subacc);
            lusers := Vault.saveUser(lusers, i.account.owner, user);

            if (not ICRC1L.validateAccount(transfer.to)) return #Err(#InvalidRecipient { block_index; instruction_index });
            if (ICRC1L.equalAccount(i.account, transfer.to)) return #Err(#InvalidTransfer { block_index; instruction_index });
            user := getLuser(transfer.to.owner);
            sub := Subaccount.get(transfer.to.subaccount);
            subacc := Vault.getSubaccount(user, sub);
            bal := Vault.getBalance(subacc, i.token);
            bal := Vault.incUnlock(bal, i.amount);
            subacc := Vault.saveBalance(subacc, i.token, bal);
            user := Vault.saveSubaccount(user, sub, subacc);
            lusers := Vault.saveUser(lusers, transfer.to.owner, user);
          };
        };
      };
      // todo: blockify
      res.add(lblock_id);
      lblock_id += 1;
    };
    for ((k, v) in RBTree.entries(lusers)) users := Vault.saveUser(users, k, v);
    block_id := lblock_id;
    #Ok(Buffer.toArray(res));
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
          case (#Deposit depo) (deposit_dedupes, Vault.dedupe, depo);
          case (#Withdraw draw) (withdraw_dedupes, Vault.dedupe, draw);
        };
        switch (RBTree.get(map, comparer, (caller, arg))) {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };
  func getToken(p : Principal) : ?(ICRC1.Canister, V.Token) = switch (RBTree.get(tokens, Principal.compare, p)) {
    case (?found) ?(actor (Principal.toText(p)), found);
    case _ null;
  };

  public shared ({ caller }) func vault_enlist_token({
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

    let config = switch (RBTree.get(tokens, Principal.compare, canister_id)) {
      case (?found) ({ found with min_deposit; deposit_fee; withdrawal_fee });
      case _ ({ min_deposit; deposit_fee; withdrawal_fee });
    };
    tokens := RBTree.insert(tokens, Principal.compare, canister_id, config);
    #Ok;
  };

  public shared ({ caller }) func vault_delist_token({
    canister_id : Principal;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    tokens := RBTree.delete(tokens, Principal.compare, canister_id);
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

  public shared query func vault_unlocked_balances_of(args : [{ account : ICRC1T.Account; token : Principal }]) : async [Nat] {
    let max_query_batch = Value.getNat(meta, V.MAX_QUERY_BATCH, 0);
    let res = Buffer.Buffer<Nat>(max_query_batch);
    label batching for (a in args.vals()) {
      let user = Vault.getUser(users, a.account.owner);
      let sub = Subaccount.get(a.account.subaccount);
      let subacc = Vault.getSubaccount(user, sub);
      let bal = Vault.getBalance(subacc, a.token);
      res.add(bal.unlocked);
      if (max_query_batch > 0 and res.size() >= max_query_batch) break batching;
    };
    Buffer.toArray(res);
  };

  public shared query func vault_locked_balances_of(args : [{ account : ICRC1T.Account; token : Principal }]) : async [Nat] {
    let max_query_batch = Value.getNat(meta, V.MAX_QUERY_BATCH, 0);
    let res = Buffer.Buffer<Nat>(max_query_batch);
    label batching for (a in args.vals()) {
      let user = Vault.getUser(users, a.account.owner);
      let sub = Subaccount.get(a.account.subaccount);
      let subacc = Vault.getSubaccount(user, sub);
      let bal = Vault.getBalance(subacc, a.token);
      res.add(bal.locked);
      if (max_query_batch > 0 and res.size() >= max_query_batch) break batching;
    };
    Buffer.toArray(res);
  };
};
