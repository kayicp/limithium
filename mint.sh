export RECEIVER="3c5hn-zbjst-c4p7o-ca7hi-jjmhh-p6nrb-lcf3d-j4gng-qsl4l-zuoug-yqe"

dfx canister call icp_token icrc1_transfer "record {
  from_subaccount = null;
  amount = 100_000_000_000_000_000;
  to = record { 
    owner = principal \"$RECEIVER\"; subaccount = null 
  };
  fee = null;
  memo = null;
  created_at_time = null;
}"

dfx canister call ckbtc_token icrc1_transfer "record {
  from_subaccount = null;
  amount = 2_100_000_000_000_000;
  to = record { 
    owner = principal \"$RECEIVER\"; subaccount = null 
  };
  fee = null;
  memo = null;
  created_at_time = null;
}"

dfx canister call cketh_token icrc1_transfer "record {
  from_subaccount = null;
  amount = 100_000_000_000_000_000_000_000;
  to = record { 
    owner = principal \"$RECEIVER\"; subaccount = null 
  };
  fee = null;
  memo = null;
  created_at_time = null;
}"

# dfx canister call xlt_token icrc1_transfer "record {
#   from_subaccount = null;
#   amount = 100_000_000_000_000_000;
#   to = record { 
#     owner = principal \"$RECEIVER\"; subaccount = null 
#   };
#   fee = null;
#   memo = null;
#   created_at_time = null;
# }"
