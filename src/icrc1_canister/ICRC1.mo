import I "Types";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Management "../util/motoko/Management";

module {
  public func default() : I.Account = {
    owner = Management.principal();
    subaccount = null;
  };

  public func validate({ owner; subaccount } : I.Account) : Bool = if (Principal.isAnonymous(owner) or Principal.equal(owner, Management.principal()) or Principal.toBlob(owner).size() > 29) false else validateSubaccount(subaccount);

  public func validateSubaccount(blob : ?Blob) : Bool = switch (blob) {
    case (?bytes) bytes.size() == 32;
    case _ true;
  };

  public func denull(blob : ?Blob) : Blob = switch blob {
    case (?found) found;
    case _ Blob.fromArray(I.default_subaccount);
  };

  public func compare(a : I.Account, b : I.Account) : Order.Order = switch (Principal.compare(a.owner, b.owner)) {
    case (#equal) Blob.compare(denull(a.subaccount), denull(b.subaccount));
    case other other;
  };

  public func equal(a : I.Account, b : I.Account) : Bool = compare(a, b) == #equal;

  public func print(a : I.Account) : Text = debug_show a;
};
