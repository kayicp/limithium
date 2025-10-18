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
export XLT_ID="g4tto-rqaaa-aaaar-qageq-cai"
export VAULT_ID="zk2nf-eaaaa-aaaar-qaiaq-cai"
export INTERNET_ID="rdmx6-jaaaa-aaaaa-aaadq-cai"

dfx deploy vault_canister --no-wallet --specified-id $VAULT_ID

dfx deploy icp_token --no-wallet --specified-id $ICP_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 10_000 : nat;
        decimals = 8 : nat;
        name = \"Internet Computer\";
        minter = principal \"$ICP_ID\";
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
        min_creation_tcycles = 10 : nat;
        max_update_batch = 4 : nat;
      };
    }
  },
)"

dfx deploy ckbtc_token --no-wallet --specified-id $CKBTC_ID --argument "(
  variant {
    Init = record {
      token = record {
        fee = 10_000 : nat;
        decimals = 8 : nat;
        name = \"Internet Computer\";
        minter = principal \"$CKBTC_ID\";
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
        min_creation_tcycles = 10 : nat;
        max_update_batch = 4 : nat;
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
        symbol = \"ICP\";
        max_approval_expiry_secs = 2_592_000 : nat;
      };
			vault = opt record {
      	id = principal \"$VAULT_ID\";
      	max_update_batch_size = 0 : nat;
      	max_mint_per_round = 100_000 : nat;
			};
      archive = record {
        min_creation_tcycles = 10 : nat;
        max_update_batch = 4 : nat;
      };
    }
  },
)"

