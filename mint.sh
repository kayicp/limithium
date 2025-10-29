export RECEIVER="zeclt-6vapj-odbdy-hgvkj-zly3b-6qe5e-wst4c-276jz-npskh-2igdk-fqe"

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
