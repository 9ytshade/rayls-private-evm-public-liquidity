#!/usr/bin/env bash
# scripts/anvil_fork_simulation.sh
# Anvil Local Fork Simulation for Rayls Public L1 (Chain ID: 72957)
# Proves:
# 1. Local mainnet forking at live block
# 2. Account impersonation via anvil_impersonateAccount
# 3. Arbitrary storage slot override via anvil_setStorageAt
# 4. Storage verification via cast storage

set -e

PORT=8545
RPC_URL="http://127.0.0.1:${PORT}"
RAYLS_MAINNET_RPC="https://mainnet-rpc.rayls.com"
FEE_AGGREGATOR="0x07E17e17e17e17E17E17E17e17E17e17e17e17E2"

echo "=============================================================================="
echo "RAYLS RESEARCH LABS: ANVIL MAINNET FORK & STORAGE OVERRIDE SIMULATION"
echo "Target Fork: ${RAYLS_MAINNET_RPC} (Chain ID: 72957)"
echo "=============================================================================="

# 1. Launch Anvil in fork mode in background
echo "[1/5] Launching Anvil fork on port ${PORT}..."
~/.foundry/bin/anvil --fork-url "${RAYLS_MAINNET_RPC}" --chain-id 72957 --port "${PORT}" > /tmp/anvil_rayls.log 2>&1 &
ANVIL_PID=$!

# Ensure Anvil is killed on exit
trap "kill -9 ${ANVIL_PID} 2>/dev/null || true" EXIT

# Wait until Anvil is responsive (up to 15 seconds)
for i in {1..15}; do
    if ~/.foundry/bin/cast block-number --rpc-url "${RPC_URL}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# 2. Query block number on local fork
FORK_BLOCK=$(~/.foundry/bin/cast block-number --rpc-url "${RPC_URL}")
echo "[2/5] Anvil successfully forked Rayls Mainnet at Block #${FORK_BLOCK}!"

# 3. Impersonate FeeAggregator Contract
echo "[3/5] Impersonating FeeAggregator Proxy (${FEE_AGGREGATOR})..."
~/.foundry/bin/cast rpc anvil_impersonateAccount "${FEE_AGGREGATOR}" --rpc-url "${RPC_URL}" > /dev/null
echo "      Account impersonation: ACTIVE"

# 4. Check initial value of storage slot 1
ORIGINAL_SLOT_1=$(~/.foundry/bin/cast storage "${FEE_AGGREGATOR}" 1 --rpc-url "${RPC_URL}")
echo "[4/5] Original Storage Slot 1: ${ORIGINAL_SLOT_1}"

# 5. Override Storage Slot 1 to simulate liquidity state mutation (0xDEADBEEF)
TARGET_OVERRIDE="0x00000000000000000000000000000000000000000000000000000000deadbeef"
echo "[5/5] Overriding Storage Slot 1 with ${TARGET_OVERRIDE} via anvil_setStorageAt..."
~/.foundry/bin/cast rpc anvil_setStorageAt \
    "${FEE_AGGREGATOR}" \
    "0x0000000000000000000000000000000000000000000000000000000000000001" \
    "${TARGET_OVERRIDE}" \
    --rpc-url "${RPC_URL}" > /dev/null

# 6. Verify overridden storage slot
UPDATED_SLOT_1=$(~/.foundry/bin/cast storage "${FEE_AGGREGATOR}" 1 --rpc-url "${RPC_URL}")
echo "      Overridden Storage Slot 1: ${UPDATED_SLOT_1}"

if [ "${UPDATED_SLOT_1}" == "${TARGET_OVERRIDE}" ]; then
    echo ""
    echo "[+] SUCCESS: Anvil storage override verified with 100% precision!"
    echo "    Demonstrated full local state mutation capability on forked Rayls Mainnet."
    
    # Export raw JSON output
    DATA_DIR="$(dirname "$0")/../data"
    mkdir -p "${DATA_DIR}"
    cat <<EOF > "${DATA_DIR}/anvil_fork_results.json"
{
  "target_rpc": "${RAYLS_MAINNET_RPC}",
  "chain_id": 72957,
  "forked_block_number": ${FORK_BLOCK},
  "impersonated_account": "${FEE_AGGREGATOR}",
  "target_storage_slot": 1,
  "original_storage_value": "${ORIGINAL_SLOT_1}",
  "overridden_storage_value": "${UPDATED_SLOT_1}",
  "mutation_success": true
}
EOF
    echo "    Exported raw results to ${DATA_DIR}/anvil_fork_results.json"
else
    echo "[-] FAILED: Slot mismatch."
    exit 1
fi
