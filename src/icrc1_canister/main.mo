import I "Types";
import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import Value "../util/motoko/Value";
import Result "../util/motoko/Result";

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

  public shared ({ caller }) func icrc1_transfer(args : I.TransferArg) : async Result.Type<Nat, I.TransferError> {
    #Ok 1;
  };

  public shared ({ caller }) func icrc2_approve(args : I.ApproveArg) : async Result.Type<Nat, I.ApproveError> {
    #Ok 1;
  };

  public shared ({ caller }) func icrc2_transfer_from(args : I.TransferFromArg) : async Result.Type<Nat, I.TransferFromError> {
    #Ok 1;
  };

  public shared ({ caller }) func lmtm_enqueue_minting_rounds(args : [{ account : I.Account; rounds : Nat }]) : async Result.Type<(), I.EnqueueErrors> {
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

  public shared query func icrc2_allowance(args : I.AllowanceArg) : async I.Allowance {
    { allowance = 0; expires_at = null };
  };

};
