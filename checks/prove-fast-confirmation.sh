#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source env/das.env
source env/validator.env
set +a

ROLLUP_ADDRESS="${ROLLUP_ADDRESS:-}"
L2_RPC_URL="${CHAIN_RPC_URL:-${SEQUENCER_FORWARDING_TARGET:-}}"
WINDOW_SECONDS="${FAST_CONFIRM_PROOF_WINDOW_SECONDS:-180}"

if [[ -z "$ROLLUP_ADDRESS" || "$ROLLUP_ADDRESS" == *"REPLACE_ME"* ]]; then
  echo "Missing ROLLUP_ADDRESS in env/validator.env (required for proof check)."
  exit 1
fi

if [[ -z "$L2_RPC_URL" || "$L2_RPC_URL" == *"REPLACE_ME"* ]]; then
  echo "Missing CHAIN_RPC_URL (preferred) or SEQUENCER_FORWARDING_TARGET in env/validator.env."
  exit 1
fi

rpc_hex_result() {
  local rpc_url="$1"
  local method="$2"
  local params_json="$3"
  curl -fsS -X POST "$rpc_url" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params_json}}" | jq -er '.result'
}

parent_eth_call() {
  local data="$1"
  rpc_hex_result "$PARENT_CHAIN_RPC" "eth_call" "[{\"to\":\"${ROLLUP_ADDRESS}\",\"data\":\"${data}\"},\"latest\"]"
}

hex_to_dec() {
  printf '%d\n' "$((16#${1#0x}))"
}

echo "Collecting baseline..."
l2_block_before_hex="$(rpc_hex_result "$L2_RPC_URL" "eth_blockNumber" "[]")"
latest_confirmed_before="$(parent_eth_call 0xb8ea9306)"

echo "Waiting ${WINDOW_SECONDS}s to observe confirmation movement..."
sleep "$WINDOW_SECONDS"

echo "Collecting follow-up sample..."
l2_block_after_hex="$(rpc_hex_result "$L2_RPC_URL" "eth_blockNumber" "[]")"
latest_confirmed_after="$(parent_eth_call 0xb8ea9306)"

l2_block_before_dec="$(hex_to_dec "$l2_block_before_hex")"
l2_block_after_dec="$(hex_to_dec "$l2_block_after_hex")"

echo "L2 blockNumber: ${l2_block_before_dec} -> ${l2_block_after_dec}"
echo "latestConfirmed: ${latest_confirmed_before} -> ${latest_confirmed_after}"

if [[ "$latest_confirmed_before" != "$latest_confirmed_after" ]]; then
  echo "PASS: latestConfirmed advanced during the observation window."
  exit 0
fi

if (( l2_block_after_dec > l2_block_before_dec )); then
  echo "FAIL: L2 produced blocks but latestConfirmed did not move."
  echo "This strongly suggests fast confirmations are not active in this window."
  exit 2
fi

echo "INCONCLUSIVE: No L2 block movement observed in the window."
echo "Increase FAST_CONFIRM_PROOF_WINDOW_SECONDS or retry during active traffic."
exit 3
