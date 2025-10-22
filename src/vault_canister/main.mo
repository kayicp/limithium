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
import Vault "Vault";
import Result "../util/motoko/Result";
import Subaccount "../util/motoko/Subaccount";
import A "../archive_canister/Types";
import ArchiveL "../archive_canister/Archive";
import Archive "../archive_canister/main";
import LEB128 "mo:leb128";
import MerkleTree "../util/motoko/MerkleTree";
import CertifiedData "mo:base/CertifiedData";
import Text "mo:base/Text";
import Option "mo:base/Option";
import ICRC3T "../util/motoko/ICRC-3/Types";
import OptionX "../util/motoko/Option";
import Cycles "mo:core/Cycles";

shared (install) persistent actor class Canister(
  deploy : {
    #Init : {
      memo_size : {
        min : Nat;
        max : Nat;
      };
      secs : {
        tx_window : Nat;
        permitted_drift : Nat;
      };
      fee_collector : Principal;
      query_max : {
        take : Nat;
        batch : Nat;
      };
      archive : {
        max_update_batch : Nat;
        min_creation_tcycles : Nat;
      };
    };
    #Upgrade;
  }
) = Self {
  var meta : Value.Metadata = RBTree.empty();
  switch deploy {
    case (#Init i) {
      meta := Value.setNat(meta, V.MIN_MEMO, ?i.memo_size.min);
      meta := Value.setNat(meta, V.MAX_MEMO, ?i.memo_size.max);
      meta := Value.setNat(meta, V.TX_WINDOW, ?i.secs.tx_window);
      meta := Value.setNat(meta, V.PERMITTED_DRIFT, ?i.secs.permitted_drift);
      meta := Value.setAccountP(meta, V.FEE_COLLECTOR, ?{ owner = i.fee_collector; subaccount = null });
      meta := Value.setNat(meta, V.MAX_TAKE, ?i.query_max.take);
      meta := Value.setNat(meta, V.MAX_QUERY_BATCH, ?i.query_max.batch);
      meta := Value.setNat(meta, A.MAX_UPDATE_BATCH_SIZE, ?i.archive.max_update_batch);
      meta := Value.setNat(meta, A.MIN_TCYCLES, ?i.archive.min_creation_tcycles);
    };
    case _ ();
  };
  var tip_cert = MerkleTree.empty();
  func updateTipCert() = CertifiedData.set(MerkleTree.treeHash(tip_cert)); // also call this on deploy.init
  system func postupgrade() = updateTipCert(); // https://gist.github.com/nomeata/f325fcd2a6692df06e38adedf9ca1877

  var users : V.Users = RBTree.empty();
  var tokens = RBTree.empty<Principal, V.Token>();
  var executors = RBTree.empty<Principal, ()>();
  var blocks = RBTree.empty<Nat, A.Block>();

  var deposit_dedupes : V.Dedupes = RBTree.empty();
  var withdraw_dedupes : V.Dedupes = RBTree.empty();

  public shared query func vault_max_take_value() : async ?Nat = async Value.metaNat(meta, V.MAX_TAKE);
  public shared query func vault_max_query_batch_size() : async ?Nat = async Value.metaNat(meta, V.MAX_QUERY_BATCH);

  public shared query func vault_tokens(prev : ?Principal, take : ?Nat) : async [Principal] {
    let maxt = Nat.min(Value.getNat(meta, V.MAX_TAKE, RBTree.size(tokens)), RBTree.size(tokens));
    RBTree.pageKey(tokens, Principal.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared query func vault_withdrawal_fees_of(token_ids : [Principal]) : async [?Nat] {
    let maxq = Nat.min(Value.getNat(meta, V.MAX_QUERY_BATCH, RBTree.size(tokens)), RBTree.size(tokens));
    let limit = Nat.min(token_ids.size(), maxq);
    let res = Buffer.Buffer<?Nat>(limit);
    label collecting for (p in token_ids.vals()) {
      switch (RBTree.get(tokens, Principal.compare, p)) {
        case (?found) res.add(?found.withdrawal_fee);
        case _ res.add(null);
      };
      if (res.size() >= limit) break collecting;
    };
    Buffer.toArray(res);
  };

  public shared query func vault_executors(prev : ?Principal, take : ?Nat) : async [Principal] {
    let maxt = Nat.min(Value.getNat(meta, V.MAX_TAKE, RBTree.size(executors)), RBTree.size(executors));
    RBTree.pageKey(executors, Principal.compare, prev, Nat.max(Option.get(take, maxt), 1));
  };

  public shared ({ caller }) func vault_deposit(arg : V.TokenArg) : async V.DepositRes {
    if (not Value.getBool(meta, V.AVAILABLE, true)) return Error.text("Unavailable");
    let user_acct = { owner = caller; subaccount = arg.subaccount };
    if (not ICRC1L.validateAccount(user_acct)) return Error.text("Caller account is not valid");

    let (token_canister, token) = switch (getToken(arg.canister_id)) {
      case (?found) found;
      case _ return Error.text("Unsupported token");
    };
    if (arg.amount < token.withdrawal_fee + 1) return #Err(#AmountTooLow { minimum_amount = token.withdrawal_fee + 1 });
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

    let env = switch (Vault.getEnvironment(meta)) {
      case (#Ok ok) ok;
      case (#Err err) return #Err err;
    };
    meta := env.meta;
    switch (checkIdempotency(caller, #Deposit arg, env, arg.created_at)) {
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

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    if (arg.created_at != null) deposit_dedupes := RBTree.insert(deposit_dedupes, Vault.dedupe, (caller, arg), block_id);
    newBlock(block_id, Vault.valueBasic("deposit", caller, arg_subacc, 0, arg, xfer_id, env.now, phash));
    await* trim(env);
    #Ok block_id;
  };

  func newBlock(block_id : Nat, val : Value.Type) {
    let valh = Value.hash(val);
    let idh = Blob.fromArray(LEB128.toUnsignedBytes(block_id));
    blocks := RBTree.insert(blocks, Nat.compare, block_id, { val; valh; idh; locked = false });

    tip_cert := MerkleTree.empty();
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_INDEX)], idh);
    tip_cert := MerkleTree.put(tip_cert, [Text.encodeUtf8(ICRC3T.LAST_BLOCK_HASH)], valh);
    updateTipCert();
  };

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
    let env = switch (Vault.getEnvironment(meta)) {
      case (#Ok ok) ok;
      case (#Err err) return #Err err;
    };
    meta := env.meta;
    switch (checkIdempotency(caller, #Withdraw arg, env, arg.created_at)) {
      case (#Err err) return #Err err;
      case _ ();
    };
    bal := Vault.decUnlock(bal, to_lock);
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

    let (block_id, phash) = ArchiveL.getPhash(blocks);
    if (arg.created_at != null) withdraw_dedupes := RBTree.insert(withdraw_dedupes, Vault.dedupe, (caller, arg), block_id);
    newBlock(block_id, Vault.valueBasic("withdraw", caller, arg_subacc, token.withdrawal_fee, arg, xfer_id, env.now, phash));
    await* trim(env);
    #Ok block_id;
  };

  public shared ({ caller }) func vault_execute(instruction_blocks : [[V.Instruction]]) : async V.ExecuteRes {
    if (not RBTree.has(executors, Principal.compare, caller)) return Error.text("Caller is not an executor");
    if (instruction_blocks.size() == 0) return Error.text("Instruction blocks must not be empty");

    var lusers : V.Users = RBTree.empty();
    func getLuser(p : Principal) : V.User = switch (RBTree.get(lusers, Principal.compare, p)) {
      case (?found) found;
      case _ Vault.getUser(users, p);
    };
    let env = switch (Vault.getEnvironment(meta)) {
      case (#Ok ok) ok;
      case (#Err err) return #Err err;
    };
    meta := env.meta;
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
    };
    for ((k, v) in RBTree.entries(lusers)) users := Vault.saveUser(users, k, v);
    let res = Buffer.Buffer<Nat>(instruction_blocks.size());
    for (b in Iter.range(0, instruction_blocks.size() - 1)) {
      let vals = Buffer.Buffer<Value.Type>(instruction_blocks[b].size());
      for (i in Iter.range(0, instruction_blocks[b].size() - 1)) vals.add(Vault.valueInstruction(instruction_blocks[b][i]));
      let (block_id, phash) = ArchiveL.getPhash(blocks);
      newBlock(block_id, Vault.valueInstructions(caller, Buffer.toArray(vals), env.now, phash));
      res.add(block_id);
    };
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
  func checkIdempotency(caller : Principal, opr : V.ArgType, env : V.Environment, created_at : ?Nat64) : Result.Type<(), { #CreatedInFuture : { ledger_time : Nat64 }; #TooOld; #Duplicate : { duplicate_of : Nat } }> {
    let ct = switch (created_at) {
      case (?defined) defined;
      case _ return #Ok;
    };
    let start_time = env.now - env.tx_window - env.permitted_drift;
    if (ct < start_time) return #Err(#TooOld);
    let end_time = env.now + env.permitted_drift;
    if (ct > end_time) return #Err(#CreatedInFuture { ledger_time = env.now });
    let (map, arg) = switch opr {
      case (#Deposit depo) (deposit_dedupes, depo);
      case (#Withdraw draw) (withdraw_dedupes, draw);
    };
    switch (RBTree.get(map, Vault.dedupe, (caller, arg))) {
      case (?duplicate_of) return #Err(#Duplicate { duplicate_of });
      case _ #Ok;
    };
  };
  func getToken(p : Principal) : ?(ICRC1.Canister, V.Token) = switch (RBTree.get(tokens, Principal.compare, p)) {
    case (?found) ?(actor (Principal.toText(p)), found);
    case _ null;
  };

  public shared ({ caller }) func vault_enlist_token({
    canister_id : Principal;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  }) : async Result.Type<(), Error.Generic> {
    if (not Principal.isController(caller)) return Error.text("Caller is not controller");

    let token = actor (Principal.toText(canister_id)) : ICRC1.Canister;
    let transfer_fee = await token.icrc1_fee();
    if (withdrawal_fee <= transfer_fee) return Error.text("withdrawal_fee must be larger than transfer fee (" # debug_show transfer_fee # ")");

    tokens := RBTree.insert(tokens, Principal.compare, canister_id, { deposit_fee; withdrawal_fee });
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

  func trim(env : V.Environment) : async* () {
    var round = 0;
    var max_round = 100;
    let start_time = env.now - env.tx_window - env.permitted_drift;
    label trimming while (round < max_round) {
      let (p, arg) = switch (RBTree.minKey(deposit_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at, ?start_time, Nat64.compare)) {
        case (#less) deposit_dedupes := RBTree.delete(deposit_dedupes, Vault.dedupe, (p, arg));
        case _ break trimming;
      };
    };
    label trimming while (round < max_round) {
      let (p, arg) = switch (RBTree.minKey(withdraw_dedupes)) {
        case (?found) found;
        case _ break trimming;
      };
      round += 1;
      switch (OptionX.compare(arg.created_at, ?start_time, Nat64.compare)) {
        case (#less) withdraw_dedupes := RBTree.delete(withdraw_dedupes, Vault.dedupe, (p, arg));
        case _ break trimming;
      };
    };
    if (round <= max_round) ignore await* sendBlock();
  };

  func sendBlock() : async* Result.Type<(), { #Sync : Error.Generic; #Async : Error.Generic }> {
    var max_batch = Value.getNat(meta, A.MAX_UPDATE_BATCH_SIZE, 0);
    if (max_batch == 0) max_batch := 1;
    if (max_batch > 100) max_batch := 100;
    meta := Value.setNat(meta, A.MAX_UPDATE_BATCH_SIZE, ?max_batch);

    if (RBTree.size(blocks) <= max_batch) return #Err(#Sync(Error.generic("Not enough blocks to archive", 0)));
    var locks = RBTree.empty<Nat, A.Block>();
    let batch_buff = Buffer.Buffer<ICRC3T.BlockResult>(max_batch);
    label collecting for ((b_id, b) in RBTree.entries(blocks)) {
      if (b.locked) return #Err(#Sync(Error.generic("Some blocks are locked for archiving", 0)));
      locks := RBTree.insert(locks, Nat.compare, b_id, b);
      batch_buff.add({ id = b_id; block = b.val });
      if (batch_buff.size() >= max_batch) break collecting;
    };
    for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = true });
    func reunlock<T>(t : T) : T {
      for ((b_id, b) in RBTree.entries(locks)) blocks := RBTree.insert(blocks, Nat.compare, b_id, { b with locked = false });
      t;
    };
    let root = switch (Value.metaPrincipal(meta, A.ROOT)) {
      case (?exist) exist;
      case _ switch (await* createArchive(null)) {
        case (#Ok created) created;
        case (#Err err) return reunlock(#Err(#Async(err)));
      };
    };
    let batch = Buffer.toArray(batch_buff);
    let start = batch[0].id;
    var prev_redir : A.Redirect = #Ask(actor (Principal.toText(root)));
    var curr_redir = prev_redir;
    var next_redir = try await (actor (Principal.toText(root)) : Archive.Canister).rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));

    label travelling while true {
      switch (ArchiveL.validateSequence(prev_redir, curr_redir, next_redir)) {
        case (#Err msg) return reunlock(#Err(#Async(Error.generic(msg, 0))));
        case _ ();
      };
      prev_redir := curr_redir;
      curr_redir := next_redir;
      next_redir := switch next_redir {
        case (#Ask cnstr) try await cnstr.rb_archive_ask(start) catch ee return reunlock(#Err(#Async(Error.convert(ee))));
        case (#Add cnstr) {
          let cnstr_id = Principal.fromActor(cnstr);
          try {
            switch (await cnstr.rb_archive_add(batch)) {
              case (#Err(#InvalidDestination r)) r;
              case (#Err(#UnexpectedBlock x)) return reunlock(#Err(#Async(Error.generic("UnexpectedBlock: " # debug_show x, 0))));
              case (#Err(#MinimumBlockViolation x)) return reunlock(#Err(#Async(Error.generic("MinimumBlockViolation: " # debug_show x, 0))));
              case (#Err(#BatchTooLarge x)) return reunlock(#Err(#Async(Error.generic("BatchTooLarge: " # debug_show x, 0))));
              case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
              case (#Ok) break travelling;
            };
          } catch ee #Create(actor (Principal.toText(cnstr_id)));
        };
        case (#Create cnstr) {
          let cnstr_id = Principal.fromActor(cnstr);
          try {
            let slave = switch (await* createArchive(?cnstr_id)) {
              case (#Err err) return reunlock(#Err(#Async(err)));
              case (#Ok created) created;
            };
            switch (await cnstr.rb_archive_create(slave)) {
              case (#Err(#InvalidDestination r)) r;
              case (#Err(#GenericError x)) return reunlock(#Err(#Async(#GenericError x)));
              case (#Ok new_root) {
                meta := Value.setPrincipal(meta, A.ROOT, ?new_root);
                meta := Value.setPrincipal(meta, A.STANDBY, null);
                #Add(actor (Principal.toText(slave)));
              };
            };
          } catch ee return reunlock(#Err(#Async(Error.convert(ee))));
        };
      };
    };
    for (b in batch.vals()) blocks := RBTree.delete(blocks, Nat.compare, b.id);
    #Ok;
  };

  func createArchive(master : ?Principal) : async* Result.Type<Principal, Error.Generic> {
    switch (Value.metaPrincipal(meta, A.STANDBY)) {
      case (?standby) return try switch (await (actor (Principal.toText(standby)) : Archive.Canister).rb_archive_initialize(master)) {
        case (#Err err) #Err err;
        case _ #Ok standby;
      } catch e #Err(Error.convert(e));
      case _ ();
    };
    var archive_tcycles = Value.getNat(meta, A.MIN_TCYCLES, 0);
    if (archive_tcycles < 3) archive_tcycles := 3;
    if (archive_tcycles > 10) archive_tcycles := 10;
    meta := Value.setNat(meta, A.MIN_TCYCLES, ?archive_tcycles);

    let trillion = 10 ** 12;
    let cost = archive_tcycles * trillion;
    let reserve = 2 * trillion;
    if (Cycles.balance() < cost + reserve) return Error.text("Insufficient cycles balance to create a new archive");

    try {
      let new_canister = await (with cycles = cost) Archive.Canister(master);
      #Ok(Principal.fromActor(new_canister));
    } catch e #Err(Error.convert(e));
  };

  public shared query func rb_archive_min_block() : async ?Nat = async RBTree.minKey(blocks);
  public shared query func rb_archive_max_update_batch_size() : async ?Nat = async Value.metaNat(meta, A.MAX_UPDATE_BATCH_SIZE);
};
