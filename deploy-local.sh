clear
# mops test

dfx stop
rm -rf .dfx
dfx start --clean --background

echo "$(dfx identity use default)"
export DEFAULT_ACCOUNT_ID=$(dfx ledger account-id)
echo "DEFAULT_ACCOUNT_ID: " $DEFAULT_ACCOUNT_ID
export DEFAULT_PRINCIPAL=$(dfx identity get-principal)

export ICP_ID="ryjl3-tyaaa-aaaaa-aaaba-cai"
export CKBTC_ID="mxzaz-hqaaa-aaaar-qaada-cai"
export CKETH_ID="ss2fx-dyaaa-aaaar-qacoq-cai"
export XLT_ID="g4tto-rqaaa-aaaar-qageq-cai"
export VAULT_ID="zk2nf-eaaaa-aaaar-qaiaq-cai"
export INTERNET_ID="rdmx6-jaaaa-aaaaa-aaadq-cai"

export CKBTC_ICP="gvqys-hyaaa-aaaar-qagfa-cai"
export CKETH_ICP="sv3dd-oaaaa-aaaar-qacoa-cai"
export XLT_ICP="vxkom-oyaaa-aaaar-qafda-cai"
export FRONTEND="xob7s-iqaaa-aaaar-qacra-cai"

dfx deploy internet_identity --no-wallet --specified-id $INTERNET_ID

dfx deploy vault_canister --no-wallet --specified-id $VAULT_ID --argument "(
  variant {
    Init = record {
      memo_size = record {
        min = 1 : nat; 
        max = 32 : nat;
      };
      secs = record {
        tx_window = 3_600 : nat;
        permitted_drift = 60 : nat;
      };
      fee_collector = principal \"$DEFAULT_PRINCIPAL\";
      query_max = record {
        take = 100 : nat;
        batch = 100 : nat;
      };
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      }; 
    }
  }
)"

dfx deploy icp_token --no-wallet --specified-id $ICP_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 10_000 : nat;
        decimals = 8 : nat;
        name = \"Internet Computer\";
        minter = principal \"$DEFAULT_PRINCIPAL\";
        permitted_drift_secs = 60 : nat;
        tx_window_secs = 3_600 : nat;
        max_supply = 100_000_000_000_000_000 : nat;
        max_memo_size = 32 : nat;
        min_memo_size = 1 : nat;
        symbol = \"ICP\";
        max_approval_expiry_secs = 2_592_000 : nat;
      };
			vault = null;
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
    }
  },
)"

dfx deploy ckbtc_token --no-wallet --specified-id $CKBTC_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 10 : nat;
        decimals = 8 : nat;
        name = \"ckBTC\";
        minter = principal \"$DEFAULT_PRINCIPAL\";
        permitted_drift_secs = 60 : nat;
        tx_window_secs = 3_600 : nat;
        max_supply = 2_100_000_000_000_000 : nat;
        max_memo_size = 32 : nat;
        min_memo_size = 1 : nat;
        symbol = \"ckBTC\";
        max_approval_expiry_secs = 2_592_000 : nat;
      };
			vault = null;
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
    }
  },
)"

dfx deploy cketh_token --no-wallet --specified-id $CKETH_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 2_000_000_000_000 : nat;
        decimals = 18 : nat;
        name = \"ckETH\";
        minter = principal \"$DEFAULT_PRINCIPAL\";
        permitted_drift_secs = 60 : nat;
        tx_window_secs = 3_600 : nat;
        max_supply = 100_000_000_000_000_000_000_000 : nat;
        max_memo_size = 32 : nat;
        min_memo_size = 1 : nat;
        symbol = \"ckETH\";
        max_approval_expiry_secs = 2_592_000 : nat;
      };
			vault = null;
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
    }
  },
)"

dfx deploy xlt_token --no-wallet --specified-id $XLT_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 10_000 : nat;
        decimals = 8 : nat;
        name = \"Limithium\";
        minter = principal \"$XLT_ID\";
        permitted_drift_secs = 60 : nat;
        tx_window_secs = 3_600 : nat;
        max_supply = 100_000_000_000_000_000 : nat;
        max_memo_size = 32 : nat;
        min_memo_size = 1 : nat;
        symbol = \"XLT\";
        max_approval_expiry_secs = 2_592_000 : nat;
      };
			vault = opt record {
      	id = principal \"$VAULT_ID\";
      	max_update_batch_size = 100 : nat;
      	max_mint_per_round = 100_000 : nat;
			};
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
    }
  },
)"

# min_amount = base_fee / min(0.1%, 0.2%) = 10 * 1000 = 10_000
# or base_fee * denom / min(maker_numer, taker_numer)
dfx deploy ckbtc_icp_book --no-wallet --specified-id $CKBTC_ICP --argument "(
  variant {
    Init = record {
      id = record {
        vault = principal \"$VAULT_ID\";
        base = principal \"$CKBTC_ID\";
        quote = principal \"$ICP_ID\";
      };
      fee = record {
        collector = principal \"$DEFAULT_PRINCIPAL\";
        numer = record { maker = 1 : nat; taker = 2 : nat };
        denom = 1_000 : nat;
        close = record { base = 20 : nat; quote = 20_000 : nat };
      };
      reward = record {
        multiplier = 1 : nat;
        token = principal \"$XLT_ID\";
      };
      memo = record { max = 32 : nat; min = 1 : nat };
      secs = record {
        ttl = 600 : nat;
        tx_window = 3_600 : nat;
        permitted_drift = 60 : nat;
        order_expiry = record { max = 3_600 : nat; min = 1_800 : nat };
      };
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
      max_order_batch = 10 : nat;
    }
  },
)"

dfx deploy cketh_icp_book --no-wallet --specified-id $CKETH_ICP --argument "(
  variant {
    Init = record {
      id = record {
        vault = principal \"$VAULT_ID\";
        base = principal \"$CKETH_ID\";
        quote = principal \"$ICP_ID\";
      };
      fee = record {
        collector = principal \"$DEFAULT_PRINCIPAL\";
        numer = record { maker = 1 : nat; taker = 2 : nat };
        denom = 1_000 : nat;
        close = record { base = 4_000_000_000_000 : nat; quote = 20_000 : nat };
      };
      reward = record {
        multiplier = 1 : nat;
        token = principal \"$XLT_ID\";
      };
      memo = record { max = 32 : nat; min = 1 : nat };
      secs = record {
        ttl = 600 : nat;
        tx_window = 3_600 : nat;
        permitted_drift = 60 : nat;
        order_expiry = record { max = 3_600 : nat; min = 1_800 : nat };
      };
      archive = record {
        min_creation_tcycles = 4 : nat;
        max_update_batch = 10 : nat;
      };
      max_order_batch = 10 : nat;
    }
  },
)"

dfx deploy frontend_canister --no-wallet --specified-id $FRONTEND

dfx canister call vault_canister vault_enlist_token "record {
  canister_id = principal \"$ICP_ID\";
  deposit_fee = 0 : nat;
  withdrawal_fee = 30_000 : nat;
}"

dfx canister call vault_canister vault_enlist_token "record {
  canister_id = principal \"$CKBTC_ID\";
  deposit_fee = 0 : nat;
  withdrawal_fee = 30 : nat;
}"

dfx canister call vault_canister vault_enlist_token "record {
  canister_id = principal \"$CKETH_ID\";
  deposit_fee = 0 : nat;
  withdrawal_fee = 6_000_000_000_000 : nat;
}"

dfx canister call vault_canister vault_enlist_token "record {
  canister_id = principal \"$XLT_ID\";
  deposit_fee = 0 : nat;
  withdrawal_fee = 30_000 : nat;
}"

dfx canister call vault_canister vault_approve_executor "record {
  canister_id = principal \"$CKBTC_ICP\";
}"

dfx canister call vault_canister vault_approve_executor "record {
  canister_id = principal \"$CKETH_ICP\";
}"
