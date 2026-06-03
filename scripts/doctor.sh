#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source env/das.env
source env/validator.env
set +a

echo "== docker compose ps =="
docker compose --env-file env/das.env --env-file env/validator.env ps

echo "== DAS RPC health =="
curl -fsS -X POST "http://${DAS_RPC_BIND:-127.0.0.1}:9876" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"das_healthCheck","params":[]}' >/dev/null
echo "OK"

echo "== DAS REST health =="
curl -fsSI "http://${DAS_REST_BIND:-127.0.0.1}:9877/health" >/dev/null
echo "OK"

echo "== Validator eth_syncing =="
docker compose --env-file env/das.env --env-file env/validator.env exec -T validator \
  curl -fsS -X POST http://127.0.0.1:8547 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}' >/dev/null
echo "OK"

echo "== Parent chain head reachable =="
curl -fsS -X POST "$PARENT_CHAIN_RPC" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' >/dev/null
echo "OK"

echo "== Fast confirmation flag configured =="
docker compose --env-file env/das.env --env-file env/validator.env exec -T validator \
  sh -lc 'tr "\0" "\n" </proc/1/cmdline | rg --quiet "^--node\.bold\.enable-fast-confirmation=true$"'
echo "OK"
echo "Note: this only verifies runtime flags, not on-chain fast-confirm cadence."

echo "Doctor checks passed."
