export RECEIVER="cor7t-2qkcq-ddumn-ncgfh-hwxch-go7bk-dczl7-km6e2-2y76i-drdf7-oqe"

#!/bin/bash

# Define a divisor variable
DIVISOR=2  # change this to whatever number you want

# Calculate divided amounts using bash arithmetic (bc handles big integers/floats)
ICP_AMOUNT=$(echo "100000000000000000 / $DIVISOR" | bc)
CKBTC_AMOUNT=$(echo "2100000000000000 / $DIVISOR" | bc)
CKETH_AMOUNT=$(echo "100000000000000000000000 / $DIVISOR" | bc)

# Call canisters with scaled amounts
dfx canister call icp_token icrc1_transfer "record {
  from_subaccount = null;
  amount = $ICP_AMOUNT;
  to = record { 
    owner = principal \"$RECEIVER\"; subaccount = null 
  };
  fee = null;
  memo = null;
  created_at_time = null;
}"

dfx canister call ckbtc_token icrc1_transfer "record {
  from_subaccount = null;
  amount = $CKBTC_AMOUNT;
  to = record { 
    owner = principal \"$RECEIVER\"; subaccount = null 
  };
  fee = null;
  memo = null;
  created_at_time = null;
}"

dfx canister call cketh_token icrc1_transfer "record {
  from_subaccount = null;
  amount = $CKETH_AMOUNT;
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
