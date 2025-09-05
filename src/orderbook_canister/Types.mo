import Result "../util/motoko/Result";
import Error "../util/motoko/Error";
import W "../wallet_canister/Types";

module {
  type OrderArg = {
    price : Nat;
    amount : Nat;
    is_buy : Bool;
    expires_at : ?Nat64;
  };
  type Fee = {
    asset : W.Asset;
    amount : Nat;
  };
  public type PlaceArg = {
    subaccount : ?Blob;
    orders : [OrderArg];
    fee : ?Fee;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type PlaceErr = {
    #GenericError : Error.Type;
    #BatchTooLarge : { batch_size : Nat; maximum_batch_size : Nat };
    #ExpiresTooSoon : {
      expires_at : Nat64;
      index : Nat;
      minimum_expires_at : Nat64;
    };
    #ExpiresTooLate : {
      expires_at : Nat64;
      index : Nat;
      maximum_expires_at : Nat64;
    };
    #BuyAmountTooLow : { amount : Nat; index : Nat; minimum_amount : Nat };
    #SellAmountTooLow : { amount : Nat; index : Nat; minimum_amount : Nat };
    #BuyPriceTooFar : { price : Nat; index : Nat; nearest_price : Nat };
    #SellPriceTooFar : { price : Nat; index : Nat; nearest_price : Nat };
    #BuyAmountTooFar : { price : Nat; index : Nat; nearest_amount : Nat };
    #SellAmountTooFar : { price : Nat; index : Nat; nearest_amount : Nat };
    #DuplicateSellPrice : { price : Nat; indexes : [Nat] };
    #DuplicateBuyPrice : { price : Nat; indexes : [Nat] };
    #OrdersOverlap : {
      sell_index : Nat;
      sell_price : Nat;
      buy_index : Nat;
      buy_price : Nat;
    };
    #BuyPriceTooHigh : { price : Nat; index : Nat; maximum_price : Nat };
    #SellPriceTooHigh : { price : Nat; index : Nat; maximum_price : Nat };
    #BuyPriceTooLow : { price : Nat; index : Nat; minimum_price : Nat };
    #SellPriceTooLow : { price : Nat; index : Nat; minimum_price : Nat };
    #SellPriceUnavailable : { price : Nat; index : Nat; order_id : Nat };
    #BuyPriceUnavailable : { price : Nat; index : Nat; order_id : Nat };
    #BadFee : { expected_fee : Nat };

  };
  public type PlaceRes = Result.Type<[(order_id : Nat)], PlaceErr>;
};
