#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAS_ENV="$ROOT_DIR/env/das.env"
VALIDATOR_ENV="$ROOT_DIR/env/validator.env"

if [[ ! -f "$DAS_ENV" ]]; then
  echo "Missing $DAS_ENV (copy from env/das.env.example)"
  exit 1
fi
if [[ ! -f "$VALIDATOR_ENV" ]]; then
  echo "Missing $VALIDATOR_ENV (copy from env/validator.env.example)"
  exit 1
fi

set -a
source "$DAS_ENV"
source "$VALIDATOR_ENV"
set +a

required_vars=(
  DAS_IMAGE
  VALIDATOR_IMAGE
  CHAIN_NAME
  PARENT_CHAIN_RPC
  PARENT_CHAIN_BEACON_RPC
  SEQUENCER_INBOX_ADDRESS
  CHAIN_INFO_JSON
  SEQUENCER_FEED_URL
  SEQUENCER_FORWARDING_TARGET
  VALIDATOR_PRIVATE_KEY
  ASSERTION_INTERVAL
)

for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable: $v"
    exit 1
  fi
done

if [[ "$VALIDATOR_PRIVATE_KEY" != 0x* ]]; then
  echo "VALIDATOR_PRIVATE_KEY must start with 0x"
  exit 1
fi

if [[ "$SEQUENCER_INBOX_ADDRESS" != 0x* ]]; then
  echo "SEQUENCER_INBOX_ADDRESS must start with 0x"
  exit 1
fi

if [[ "$SEQUENCER_FEED_URL" == *".svc.cluster.local"* ]]; then
  echo "SEQUENCER_FEED_URL must be externally reachable for external hosts"
  exit 1
fi

if [[ "$DAS_IMAGE" == *"REPLACE_ME"* || "$VALIDATOR_IMAGE" == *"REPLACE_ME"* ]]; then
  echo "Image references still contain REPLACE_ME placeholders"
  exit 1
fi

if [[ "$PARENT_CHAIN_RPC" == *"REPLACE_ME"* || "$PARENT_CHAIN_BEACON_RPC" == *"REPLACE_ME"* ]]; then
  echo "RPC URLs still contain REPLACE_ME placeholders"
  exit 1
fi

if [[ ! -d "$ROOT_DIR/bls_keys" ]]; then
  echo "Missing $ROOT_DIR/bls_keys directory"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/bls_keys/das_bls" || ! -f "$ROOT_DIR/bls_keys/das_bls.pub" ]]; then
  echo "Missing DAS BLS keypair in $ROOT_DIR/bls_keys"
  exit 1
fi

echo "Environment validation passed."
