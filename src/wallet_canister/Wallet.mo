import RBTree "../util/motoko/StableCollections/RedBlackTree/RBTree";
import W "Types";
import Principal "mo:base/Principal";

module {
  public func recycleId<K>(ids : RBTree.Type<Nat, K>) : Nat = switch (RBTree.minKey(ids), RBTree.maxKey(ids)) {
    case (?min_id, ?max_id) if (min_id > 0) min_id - 1 else max_id + 1;
    case _ 0;
  };
};
