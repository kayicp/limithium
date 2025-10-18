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
import A "../archive_canister/Types";
import ArchiveL "../archive_canister/Archive";
import Archive "../archive_canister/main";
import LEB128 "mo:leb128";
import MerkleTree "../util/motoko/MerkleTree";
import CertifiedData "mo:base/CertifiedData";
import Text "mo:base/Text";
import ICRC3T "../util/motoko/ICRC-3/Types";
import OptionX "../util/motoko/Option";
import Cycles "mo:core/Cycles";

shared (install) persistent actor class Canister(
  // deploy : {
  //   #Init : ();
  //   #Upgrade;
  // }
) = Self {
  var tip_cert = MerkleTree.empty();
  func updateTipCert() = CertifiedData.set(MerkleTree.treeHash(tip_cert)); // also call this on deploy.init
  system func postupgrade() = updateTipCert(); // https://gist.github.com/nomeata/f325fcd2a6692df06e38adedf9ca1877

  var users : I.Users = RBTree.empty();
  var meta = RBTree.empty<Text, Value.Type>();

  var blocks = RBTree.empty<Nat, A.Block>();

  // todo: trim these dedupes
  var transfer_dedupes = RBTree.empty<(Principal, I.TransferArg), Nat>();
  var approve_dedupes = RBTree.empty<(Principal, I.ApproveArg), Nat>();
  var transfer_from_dedupes = RBTree.empty<(Principal, I.TransferFromArg), Nat>();
  var approval_by_expiry : I.Expiries = RBTree.empty();

  var prev_mint : ?Nat = null;
  var mint_queue = RBTree.empty<Nat, I.Enqueue>();

  func newBlock(block_id : Nat, val : Value.Type) {
    let valh = Value.hash(val);
    let idh = Blob.fromArray(LEB128.toUnsignedBytes(block_id));
    blocks := RBTree.insert(blocks, Nat.compare, block_id, { val; valh; idh; locked = false });

    tip_cert := MerkleTree.empty();
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_INDEX)], idh);
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_HASH)], valh);
    updateTipCert();
  };

  public shared ({ caller }) func icrc1_transfer(arg : I.TransferArg) : async Result.Type<Nat, I.TransferError> {
    if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
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
    let is_transfer = not is_burn and not is_mint;
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
    switch (checkIdempotency(caller, #Transfer arg, env, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };

    subacc := ICRC1.decBalance(subacc, transfer_and_fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(caller, user);

    user := getUser(arg.to.owner);
    sub := Subaccount.get(arg.to.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, arg.amount);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(arg.to.owner, user);

    if (expected_fee > 0) {
      user := getUser(env.minter.owner);
      sub := Subaccount.get(env.minter.subaccount);
      subacc := ICRC1.getSubaccount(user, sub);
      subacc := ICRC1.incBalance(subacc, expected_fee);
      user := ICRC1.saveSubaccount(user, sub, subacc);
      saveUser(env.minter.owner, user);
    };

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    if (arg.created_at_time != null) transfer_dedupes := RBTree.insert(transfer_dedupes, ICRC1.dedupeTransfer, (caller, arg), block_id);
    newBlock(block_id, ICRC1.valueTransfer(caller, arg, if (is_burn) #Burn else if (is_mint) #Mint else #Transfer, expected_fee, env.now, phash));
    trim(env);
    #Ok block_id;
  };

  public shared ({ caller }) func icrc2_approve(arg : I.ApproveArg) : async Result.Type<Nat, I.ApproveError> {
    if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
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
    switch (checkIdempotency(caller, #Approve arg, env, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    spender := ICRC1.saveApproval(spender, spender_sub, arg.amount, expires_at);
    subacc := ICRC1.saveSpender(subacc, arg.spender.owner, spender);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(caller, user);

    approval_by_expiry := ICRC1.newExpiry(approval_by_expiry, expires_at, caller, sub, arg.spender.owner, spender_sub);

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    if (arg.created_at_time != null) approve_dedupes := RBTree.insert(approve_dedupes, ICRC1.dedupeApprove, (caller, arg), block_id);
    newBlock(block_id, ICRC1.valueApprove(caller, arg, expires_at, env.fee, env.now, phash));
    trim(env);
    #Ok block_id;
  };

  public shared ({ caller }) func icrc2_transfer_from(arg : I.TransferFromArg) : async Result.Type<Nat, I.TransferFromError> {
    if (not Value.getBool(meta, I.AVAILABLE, true)) return #Err(#TemporarilyUnavailable);
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
    switch (checkIdempotency(caller, #TransferFrom arg, env, arg.created_at_time)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    approval := ICRC1.decApproval(approval, transfer_and_fee);
    spender := ICRC1.saveApproval(spender, spender_sub, approval.allowance, approval.expires_at);
    subacc := ICRC1.saveSpender(subacc, caller, spender);
    subacc := ICRC1.decBalance(subacc, transfer_and_fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(caller, user);

    user := getUser(arg.to.owner);
    sub := Subaccount.get(arg.to.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, arg.amount);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(arg.to.owner, user);

    user := getUser(env.minter.owner);
    sub := Subaccount.get(env.minter.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, env.fee);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(env.minter.owner, user);

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    if (arg.created_at_time != null) transfer_from_dedupes := RBTree.insert(transfer_from_dedupes, ICRC1.dedupeTransferFrom, (caller, arg), block_id);
    newBlock(block_id, ICRC1.valueTransferFrom(caller, arg, env.fee, env.now, phash));
    trim(env);
    #Ok block_id;
  };

  public shared query func xlt_max_update_batch_size() : async ?Nat = async Value.metaNat(meta, I.MAX_UPDATE_BATCH);
  public shared ({ caller }) func xlt_enqueue_minting_rounds(enqueues : [I.Enqueue]) : async Result.Type<(), I.EnqueueErrors> {
    if (not Value.getBool(meta, I.AVAILABLE, true)) return Error.text("Unavailable");
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

    var max_batch_size = Value.getNat(meta, I.MAX_UPDATE_BATCH, 0);
    if (max_batch_size < 1) max_batch_size := 1;
    if (max_batch_size > 100) max_batch_size := 100;
    meta := Value.setNat(meta, I.MAX_UPDATE_BATCH, ?max_batch_size);
    if (enqueues.size() > max_batch_size) return #Err(#BatchTooLarge { batch_size = enqueues.size(); maximum_batch_size = max_batch_size });

    var id = switch (RBTree.maxKey(mint_queue)) {
      case (?max) max + 1;
      case _ 0;
    };
    label filtering for (i in Iter.range(0, enqueues.size() - 1)) {
      let q = enqueues[i];
      if (q.rounds == 0) continue filtering;
      if (not ICRC1.validateAccount(q.account)) continue filtering;
      if (ICRC1.equalAccount(q.account, env.minter)) continue filtering;
      mint_queue := RBTree.insert(mint_queue, Nat.compare, id, q);
      id += 1;
    };
    trim(env);
    #Ok;
  };

  func trim(env : I.Environment) {
    var round = 0;
    var max_round = 100;
    label trimming while (round < max_round) {
      let (p, arg) = switch (RBTree.minKey(transfer_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at_time, ?env.dedupe_start, Nat64.compare)) {
        case (#less) transfer_dedupes := RBTree.delete(transfer_dedupes, ICRC1.dedupeTransfer, (p, arg));
        case _ break trimming;
      };
    };
    label trimming while (round < max_round) {
      let (p, arg) = switch (RBTree.minKey(approve_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at_time, ?env.dedupe_start, Nat64.compare)) {
        case (#less) approve_dedupes := RBTree.delete(approve_dedupes, ICRC1.dedupeApprove, (p, arg));
        case _ break trimming;
      };
    };
    label trimming while (round < max_round) {
      let (p, arg) = switch (RBTree.minKey(transfer_from_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at_time, ?env.dedupe_start, Nat64.compare)) {
        case (#less) transfer_from_dedupes := RBTree.delete(transfer_from_dedupes, ICRC1.dedupeTransferFrom, (p, arg));
        case _ break trimming;
      };
    };
    label trimming while (round < max_round) {
      switch prev_mint {
        case (?prev) switch (RBTree.right(mint_queue, Nat.compare, prev)) {
          case (?(next, nextq)) if (mint_round(next, nextq, env)) prev_mint := ?next else break trimming;
          case _ prev_mint := null;
        };
        case _ switch (RBTree.min(mint_queue)) {
          case (?(min, minq)) if (mint_round(min, minq, env)) prev_mint := ?min else break trimming;
          case _ break trimming;
        };
      };
      round += 1;
    };
  };
  func mint_round(qid : Nat, q : I.Enqueue, env : I.Environment) : Bool {
    if (q.rounds == 0) {
      mint_queue := RBTree.delete(mint_queue, Nat.compare, qid);
      return true;
    };
    var user = getUser(env.minter.owner); // take from minter
    var sub = Subaccount.get(env.minter.subaccount);
    var subacc = ICRC1.getSubaccount(user, sub);

    if (subacc.balance == 0) return false; // not mintable
    let mint = Nat.max((env.max_mint * subacc.balance) / env.total_supply, 1);
    subacc := ICRC1.decBalance(subacc, mint);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(env.minter.owner, user);

    user := getUser(q.account.owner); // give to user
    sub := Subaccount.get(q.account.subaccount);
    subacc := ICRC1.getSubaccount(user, sub);
    subacc := ICRC1.incBalance(subacc, mint);
    user := ICRC1.saveSubaccount(user, sub, subacc);
    saveUser(q.account.owner, user);

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    newBlock(block_id, ICRC1.valueTransfer(env.minter.owner, { to = q.account; fee = null; memo = null; from_subaccount = env.minter.subaccount; created_at_time = null; amount = mint }, #Mint, 0, env.now, phash));

    mint_queue := if (q.rounds > 1) {
      RBTree.insert(mint_queue, Nat.compare, qid, { q with rounds = q.rounds - 1 });
    } else RBTree.delete(mint_queue, Nat.compare, qid); // done minting, remove it
    true;
  };

  public shared query func icrc1_name() : async Text = async "Limithium";
  public shared query func icrc1_symbol() : async Text = async "XLT";
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
  func saveUser(p : Principal, u : I.Subaccounts) = users := if (RBTree.size(u) > 0) RBTree.insert(users, Principal.compare, p, u) else RBTree.delete(users, Principal.compare, p);

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
  func checkIdempotency(caller : Principal, opr : I.ArgType, env : I.Environment, created_at : ?Nat64) : Result.Type<(), { #CreatedInFuture : { ledger_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    let ct = switch (created_at) {
      case (?defined) defined;
      case _ return #Ok;
    };
    if (ct < env.dedupe_start) return #Err(#TooOld);
    if (ct > env.dedupe_end) return #Err(#CreatedInFuture { ledger_time = env.now });
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

  // func sendBlock() : async* Result.Type<(), { #Sync : Error.Generic; #Async : Error.Generic }> {
  //   var max_batch = Value.getNat(meta, A.MAX_UPDATE_BATCH_SIZE, 0);
  //   if (max_batch == 0) max_batch := 1;
  //   if (max_batch > 100) max_batch := 100;
  //   meta := Value.setNat(meta, A.MAX_UPDATE_BATCH_SIZE, ?max_batch);

  //   if (RBTree.size(blocks) <= max_batch) return #Err(#Sync(Error.generic("Not enough blocks to archive", 0)));
  //   var locks = RBTree.empty<Nat, A.Block>();
  //   let batch_buff = Buffer.Buffer<ICRC3T.BlockResult>(max_batch);
  //   label collecting for ((b_id, b) in RBTree.entries(blocks)) {
  //     if (b.locked) return #Err(#Sync(Error.generic("Some blocks are locked for archiving", 0)));
  //     locks := RBTree.insert(locks, Nat.compare, b_id, b);
  //     batch_buff.add({ id = b_id; block = b.val });
  //     if (batch_buff.size() >= max_batch) break collecting;
  //   };
  //   for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = true });
  //   func reunlock<T>(t : T) : T {
  //     for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = false });
  //     t;
  //   };
  //   let root = switch (Value.metaPrincipal(meta, A.ROOT)) {
  //     case (?exist) exist;
  //     case _ switch (await* createArchive(null)) {
  //       case (#Ok created) created;
  //       case (#Err err) return reunlock(#Err(#Async(err)));
  //     };
  //   };
  //   let batch = Buffer.toArray(batch_buff);
  //   let start = batch[0].id;
  //   var prev_redir : A.Redirect = #Ask(actor (Principal.toText(root)));
  //   var curr_redir = prev_redir;
  //   var next_redir = try await (actor (Principal.toText(root)) : Archive.Canister).rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));

  //   label travelling while true {
  //     switch (ArchiveL.validateSequence(prev_redir, curr_redir, next_redir)) {
  //       case (#Err msg) return reunlock(#Err(#Async(Error.generic(msg, 0))));
  //       case _ ();
  //     };
  //     prev_redir := curr_redir;
  //     curr_redir := next_redir;
  //     next_redir := switch next_redir {
  //       case (#Ask cnstr) try await cnstr.rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));
  //       case (#Add cnstr) {
  //         let cnstr_id = Principal.fromActor(cnstr);
  //         try {
  //           switch (await cnstr.rb_archive_add(batch)) {
  //             case (#Err(#InvalidDestination r)) r;
  //             case (#Err(#UnexpectedBlock x)) return reunlock(#Err(#Async(Error.generic("UnexpectedBlock: " # debug_show x, 0))));
  //             case (#Err(#MinimumBlockViolation x)) return reunlock(#Err(#Async(Error.generic("MinimumBlockViolation: " # debug_show x, 0))));
  //             case (#Err(#BatchTooLarge x)) return reunlock(#Err(#Async(Error.generic("BatchTooLarge: " # debug_show x, 0))));
  //             case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
  //             case (#Ok) break travelling;
  //           };
  //         } catch ee #Create(actor (Principal.toText(cnstr_id)));
  //       };
  //       case (#Create cnstr) {
  //         let cnstr_id = Principal.fromActor(cnstr);
  //         try {
  //           let slave = switch (await* createArchive(?cnstr_id)) {
  //             case (#Err err) return reunlock(#Err(#Async(err)));
  //             case (#Ok created) created;
  //           };
  //           switch (await cnstr.rb_archive_create(slave)) {
  //             case (#Err(#InvalidDestination r)) r;
  //             case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
  //             case (#Ok new_root) {
  //               meta := Value.setPrincipal(meta, A.ROOT, ?new_root);
  //               meta := Value.setPrincipal(meta, A.STANDBY, null);
  //               #Add(actor (Principal.toText(slave)));
  //             };
  //           };
  //         } catch ee return reunlock(#Err(#Async(Error.convert(ee))));
  //       };
  //     };
  //   };
  //   for (b in batch.vals()) blocks := RBTree.delete(blocks, Nat.compare, b.id);
  //   #Ok;
  // };

  // func createArchive(master : ?Principal) : async* Result.Type<Principal, Error.Generic> {
  //   switch (Value.metaPrincipal(meta, A.STANDBY)) {
  //     case (?standby) return try switch (await (actor (Principal.toText(standby)) : Archive.Canister).rb_archive_initialize(master)) {
  //       case (#Err err) #Err err;
  //       case _ #Ok standby;
  //     } catch e #Err(Error.convert(e));
  //     case _ ();
  //   };
  //   var archive_tcycles = Value.getNat(meta, A.MIN_TCYCLES, 0);
  //   if (archive_tcycles < 3) archive_tcycles := 3;
  //   if (archive_tcycles > 10) archive_tcycles := 10;
  //   meta := Value.setNat(meta, A.MIN_TCYCLES, ?archive_tcycles);

  //   let trillion = 10 ** 12;
  //   let cost = archive_tcycles * trillion;
  //   let reserve = 2 * trillion;
  //   if (Cycles.balance() < cost + reserve) return Error.text("Insufficient cycles balance to create a new archive");

  //   try {
  //     let new_canister = await (with cycles = cost) Archive.Canister(master);
  //     #Ok(Principal.fromActor(new_canister));
  //   } catch e #Err(Error.convert(e));
  // };
};
