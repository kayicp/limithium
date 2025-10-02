import I "Types";
import ICRC1 "ICRC1";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Value "../util/motoko/Value";
import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import Nat64 "mo:base/Nat64";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Time64 "../util/motoko/Time64";
import Subaccount "../util/motoko/Subaccount";
import V "../vault_canister/Types";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var users : I.Users = RBTree.empty();
  var meta = RBTree.empty<Text, Value.Type>();

  var block_id = 0;
  var blocks = RBTree.empty<Nat, Value.Type>();

  var transfer_dedupes = RBTree.empty<(Principal, I.TransferArg), Nat>();
  var approve_dedupes = RBTree.empty<(Principal, I.ApproveArg), Nat>();
  var transfer_from_dedupes = RBTree.empty<(Principal, I.TransferFromArg), Nat>();

  public shared ({ caller }) func icrc1_transfer(arg : I.TransferArg) : async Result.Type<Nat, I.TransferError> {
    // if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
    let from = { owner = caller; subaccount = arg.from_subaccount };
    if (not ICRC1.validateAccount(from)) return Error.text("Caller account is invalid");
    if (not ICRC1.validateAccount(arg.to)) return Error.text("`To` account is invalid");
    if (ICRC1.equalAccount(from, arg.to)) return Error.text("Self-transfer is prohibited");
    if (arg.amount == 0) return Error.text("`Amount` must be larger than zero");
    let env = switch (ICRC1.getEnvironment(meta)) {
      case (#Err err) return Error.text(err);
      case (#Ok ok) ok;
    };
    meta := env.meta;

    let is_burn = ICRC1.equalAccount(arg.to, env.minter);
    if (is_burn and arg.amount < env.fee) return #Err(#BadBurn { min_burn_amount = env.fee });

    let is_mint = ICRC1.equalAccount(from, env.minter);
    let is_transfer = not (is_burn or is_mint);
    let expected_fee = if (is_transfer) env.fee else 0;
    switch (arg.fee) {
      case (?defined) if (defined != expected_fee) return #Err(#BadFee { expected_fee });
      case _ ();
    };
    let transfer_and_fee = arg.amount + expected_fee;

    var user = getUser(caller);
    var sub = Subaccount.get(from.subaccount);
    var subacc = ICRC1.getSubaccount(user, sub);
    if (subacc.balance < transfer_and_fee) return #Err(#InsufficientFunds subacc);

    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #Transfer arg, env.now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };

    subacc := ICRC1.decBalance(subacc, transfer_and_fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    user := getUser(arg.to.owner);
    sub := Subaccount.get(arg.to.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, arg.amount);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(arg.to.owner, user);

    if (expected_fee > 0) {
      user := getUser(env.minter.owner);
      sub := Subaccount.get(env.minter.subaccount);
      subacc := ICRC1.getSubaccount(user, sub);
      subacc := ICRC1.incBalance(subacc, expected_fee);
      user := ICRC1.saveSubaccount(user, sub, subacc);
      user := saveUser(env.minter.owner, user);
    };

    // todo: blockify
    // todo: save dedupe
    #Ok 1;
  };

  public shared ({ caller }) func icrc2_approve(arg : I.ApproveArg) : async Result.Type<Nat, I.ApproveError> {
    // if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
    let from = { owner = caller; subaccount = arg.from_subaccount };
    if (not ICRC1.validateAccount(from)) return Error.text("Caller account is invalid");
    if (not ICRC1.validateAccount(arg.spender)) return Error.text("Spender account is invalid");

    let env = switch (ICRC1.getEnvironment(meta)) {
      case (#Err err) return Error.text(err);
      case (#Ok ok) ok;
    };
    meta := env.meta;

    if (ICRC1.equalAccount(from, env.minter)) return Error.text("Minter cannot approve");
    if (ICRC1.equalAccount(arg.spender, env.minter)) return Error.text("Cannot approve minter");
    if (ICRC1.equalAccount(from, arg.spender)) return Error.text("Self-approve is prohibited");

    switch (arg.fee) {
      case (?defined) if (defined != env.fee) return #Err(#BadFee { expected_fee = env.fee });
      case _ ();
    };
    let expiry = ICRC1.getExpiry(meta, env.now);
    meta := expiry.meta;
    let expires_at = switch (arg.expires_at) {
      case (?defined) {
        if (defined < env.now) return #Err(#Expired { ledger_time = env.now });
        if (defined > expiry.max) return Error.text("Expires too late (max: " # debug_show (expiry.max) # ")") else defined;
      };
      case _ expiry.max;
    };
    var user = getUser(caller);
    let sub = Subaccount.get(from.subaccount);
    var subacc = ICRC1.getSubaccount(user, sub);
    if (subacc.balance < env.fee) return #Err(#InsufficientFunds subacc);

    var spender = ICRC1.getSpender(subacc, arg.spender.owner);
    let spender_sub = Subaccount.get(arg.spender.subaccount);
    let approval = ICRC1.getApproval(spender, spender_sub);
    switch (arg.expected_allowance) {
      case (?defined) if (defined != approval.allowance) return #Err(#AllowanceChanged { current_allowance = approval.allowance });
      case _ ();
    };
    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #Approve arg, env.now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    spender := ICRC1.saveApproval(spender, spender_sub, arg.amount, expires_at);
    subacc := ICRC1.saveSpender(subacc, arg.spender.owner, spender);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    // todo: blockify
    // todo: save dedupe
    // todo: register expiry
    #Ok 1;
  };

  public shared ({ caller }) func icrc2_transfer_from(arg : I.TransferFromArg) : async Result.Type<Nat, I.TransferFromError> {
    // if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
    let spender_acc = { owner = caller; subaccount = arg.spender_subaccount };
    if (not ICRC1.validateAccount(spender_acc)) return Error.text("Caller account is invalid");
    if (not ICRC1.validateAccount(arg.from)) return Error.text("`From` account is invalid");
    if (not ICRC1.validateAccount(arg.to)) return Error.text("`To` account is invalid");

    let env = switch (ICRC1.getEnvironment(meta)) {
      case (#Err err) return Error.text(err);
      case (#Ok ok) ok;
    };
    meta := env.meta;

    if (ICRC1.equalAccount(spender_acc, env.minter)) return Error.text("Minter cannot spend");
    if (ICRC1.equalAccount(arg.from, env.minter)) return Error.text("Cannot spend minter");
    if (ICRC1.equalAccount(arg.from, spender_acc)) return Error.text("Self-spend is prohibited");
    if (ICRC1.equalAccount(arg.from, arg.to)) return Error.text("Self-transfer is prohibited");
    if (ICRC1.equalAccount(arg.to, env.minter)) return Error.text("Burn is prohibited");
    if (arg.amount == 0) return Error.text("`Amount` must be larger than zero");

    switch (arg.fee) {
      case (?defined) if (defined != env.fee) return #Err(#BadFee { expected_fee = env.fee });
      case _ ();
    };
    let transfer_and_fee = arg.amount + env.fee;
    var user = getUser(arg.from.owner);
    var sub = Subaccount.get(arg.from.subaccount);
    var subacc = ICRC1.getSubaccount(user, sub);

    var spender = ICRC1.getSpender(subacc, caller);
    let spender_sub = Subaccount.get(arg.spender_subaccount);
    var approval = ICRC1.getApproval(spender, spender_sub);
    if (approval.expires_at < env.now) return #Err(#InsufficientAllowance { allowance = 0 });
    if (approval.allowance < transfer_and_fee) return #Err(#InsufficientAllowance approval);
    if (subacc.balance < transfer_and_fee) return #Err(#InsufficientFunds subacc);

    switch (checkMemo(arg.memo)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    switch (checkIdempotency(caller, #TransferFrom arg, env.now, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    approval := ICRC1.decApproval(approval, transfer_and_fee);
    spender := ICRC1.saveApproval(spender, spender_sub, approval.allowance, approval.expires_at);
    subacc := ICRC1.saveSpender(subacc, caller, spender);
    subacc := ICRC1.decBalance(subacc, transfer_and_fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(caller, user);

    user := getUser(arg.to.owner);
    sub := Subaccount.get(arg.to.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, arg.amount);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(arg.to.owner, user);

    user := getUser(env.minter.owner);
    sub := Subaccount.get(env.minter.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, env.fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    user := saveUser(env.minter.owner, user);

    // todo: blockify
    // todo: save dedupe

    #Ok 1;
  };

  var mint_qid = 0;
  var mint_queue = RBTree.empty<Nat, I.Enqueue>();
  public shared ({ caller }) func lmtm_enqueue_minting_rounds(enqueues : [I.Enqueue]) : async Result.Type<(), I.EnqueueErrors> {
    // if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
    let vault_id = switch (Value.metaPrincipal(meta, I.VAULT)) {
      case (?found) found;
      case _ return Error.text("Metadata `" # I.VAULT # "` is not set");
    };
    if (caller != vault_id) {
      let vault = actor (Principal.toText(vault_id)) : V.Actor;
      let is_executor = await vault.vault_is_executor(caller);
      if (not is_executor) return Error.text("Caller is not a subminter");
    };
    if (enqueues.size() == 0) return #Ok;
    let env = switch (ICRC1.getEnvironment(meta)) {
      case (#Ok ok) ok;
      case (#Err err) return Error.text(err);
    };
    meta := env.meta;
    let total_supply = Value.getNat(meta, I.TOTAL_SUPPLY, 0);
    if (10_000 * env.fee > total_supply) return Error.text("Metadata `" # I.TOTAL_SUPPLY # "` must be at least 10,000 times bigger than the fee");

    let max_mint = 10 * env.fee;
    label distributing for (i in Iter.range(0, enqueues.size() - 1)) {
      let q = enqueues[i];
      if (q.rounds == 0) continue distributing;
      if (not ICRC1.validateAccount(q.account)) continue distributing;
      if (ICRC1.equalAccount(q.account, env.minter)) continue distributing;

      var user = getUser(env.minter.owner); // take from minter
      var sub = Subaccount.get(env.minter.subaccount);
      var subacc = ICRC1.getSubaccount(user, sub);

      if (subacc.balance == 0) {
        mint_queue := RBTree.insert(mint_queue, Nat.compare, mint_qid, q);
        mint_qid += 1;
        continue distributing;
      };
      let mint = (max_mint * subacc.balance) / total_supply;
      if (mint == 0) {
        mint_queue := RBTree.insert(mint_queue, Nat.compare, mint_qid, q);
        mint_qid += 1;
        continue distributing;
      };
      subacc := ICRC1.decBalance(subacc, mint);
      user := ICRC1.saveSubaccount(user, sub, subacc);
      user := saveUser(env.minter.owner, user);

      user := getUser(q.account.owner); // give to user
      sub := Subaccount.get(q.account.subaccount);
      subacc := ICRC1.getSubaccount(user, sub);
      subacc := ICRC1.incBalance(subacc, mint);
      user := ICRC1.saveSubaccount(user, sub, subacc);
      user := saveUser(q.account.owner, user);

      // todo: blockify

      if (q.rounds == 1) continue distributing; // done mint, no enqueue
      mint_queue := RBTree.insert(mint_queue, Nat.compare, mint_qid, { q with rounds = q.rounds - 1 }); // safe, rounds > 1
      mint_qid += 1;
    };
    #Ok;
  };

  public shared query func icrc1_name() : async Text = async "Limithium";
  public shared query func icrc1_symbol() : async Text = async "LMTM";
  public shared query func icrc1_decimals() : async Nat8 = async 8;
  public shared query func icrc1_fee() : async Nat = async 10_000;
  public shared query func icrc1_metadata() : async [(Text, Value.Type)] = async [];
  public shared query func icrc1_total_supply() : async Nat = async 0;
  public shared query func icrc1_minting_account() : async ?I.Account = async null;

  public shared query func icrc1_balance_of(acc : I.Account) : async Nat {
    0;
  };

  type Standard = { name : Text; url : Text };
  public shared query func icrc1_supported_standards() : async [Standard] = async [];

  public shared query func icrc2_allowance(arg : I.AllowanceArg) : async I.Allowance {
    { allowance = 0; expires_at = null };
  };

  func getUser(p : Principal) : I.Subaccounts = switch (RBTree.get(users, Principal.compare, p)) {
    case (?found) found;
    case _ RBTree.empty();
  };
  func saveUser(p : Principal, u : I.Subaccounts) : I.Subaccounts {
    users := if (RBTree.size(u) > 0) RBTree.insert(users, Principal.compare, p, u) else RBTree.delete(users, Principal.compare, p);
    u;
  };

  func checkMemo(m : ?Blob) : Result.Type<(), Error.Generic> = switch m {
    case (?defined) {
      var min_memo_size = Value.getNat(meta, I.MIN_MEMO, 1);
      if (min_memo_size < 1) {
        min_memo_size := 1;
        meta := Value.setNat(meta, I.MIN_MEMO, ?min_memo_size);
      };
      if (defined.size() < min_memo_size) return Error.text("Memo size must be larger than " # debug_show min_memo_size);

      var max_memo_size = Value.getNat(meta, I.MAX_MEMO, 1);
      if (max_memo_size < min_memo_size) {
        max_memo_size := min_memo_size;
        meta := Value.setNat(meta, I.MAX_MEMO, ?max_memo_size);
      };
      if (defined.size() > max_memo_size) return Error.text("Memo size must be smaller than " # debug_show max_memo_size);
      #Ok;
    };
    case _ #Ok;
  };
  func checkIdempotency(caller : Principal, opr : I.ArgType, now : Nat64, created_at_time : ?Nat64) : Result.Type<(), { #CreatedInFuture : { ledger_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    var tx_window = Nat64.fromNat(Value.getNat(meta, I.TX_WINDOW, 0));
    let min_tx_window = Time64.MINUTES(15);
    if (tx_window < min_tx_window) {
      tx_window := min_tx_window;
      meta := Value.setNat(meta, I.TX_WINDOW, ?(Nat64.toNat(tx_window)));
    };
    var permitted_drift = Nat64.fromNat(Value.getNat(meta, I.PERMITTED_DRIFT, 0));
    let min_permitted_drift = Time64.SECONDS(5);
    if (permitted_drift < min_permitted_drift) {
      permitted_drift := min_permitted_drift;
      meta := Value.setNat(meta, I.PERMITTED_DRIFT, ?(Nat64.toNat(permitted_drift)));
    };
    switch (created_at_time) {
      case (?created_time) {
        let start_time = now - tx_window - permitted_drift;
        if (created_time < start_time) return #Err(#TooOld);
        let end_time = now + permitted_drift;
        if (created_time > end_time) return #Err(#CreatedInFuture { ledger_time = now });
        let found_block = switch opr {
          case (#Transfer xfer) RBTree.get(transfer_dedupes, ICRC1.dedupeTransfer, (caller, xfer));
          case (#Approve appr) RBTree.get(approve_dedupes, ICRC1.dedupeApprove, (caller, appr));
          case (#TransferFrom xfer) RBTree.get(transfer_from_dedupes, ICRC1.dedupeTransferFrom, (caller, xfer));
        };
        switch found_block {
          case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
          case _ #Ok;
        };
      };
      case _ #Ok;
    };
  };
};
