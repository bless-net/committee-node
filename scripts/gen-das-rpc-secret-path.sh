#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NETWORK_ENV="$ROOT_DIR/env/das.network.env"
FORCE=false
PRINT_ONLY=false

usage() {
  cat <<'EOF'
Usage: gen-das-rpc-secret-path.sh [options]

Generate DAS_RPC_SECRET_PATH (openssl rand -hex 16) for nginx RPC URL.

Options:
  --force       Replace an existing non-placeholder value (requires keyset coordination)
  --print-only  Print a new secret to stdout; do not edit env/das.network.env
  -h, --help    Show this help

Without options: update env/das.network.env if DAS_RPC_SECRET_PATH is unset or REPLACE_ME.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --print-only) PRINT_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SECRET="$(openssl rand -hex 16)"

if $PRINT_ONLY; then
  echo "$SECRET"
  exit 0
fi

if [[ ! -f "$NETWORK_ENV" ]]; then
  echo "Missing $NETWORK_ENV"
  echo "Run: cp env/das.network.env.example env/das.network.env && chmod 600 env/das.network.env"
  exit 1
fi

current="$(grep -E '^DAS_RPC_SECRET_PATH=' "$NETWORK_ENV" | head -n1 | cut -d= -f2- || true)"

if [[ -n "$current" && "$current" != REPLACE_ME* && "$FORCE" != true ]]; then
  echo "DAS_RPC_SECRET_PATH is already set in env/das.network.env."
  echo "Use --force to replace (requires Blessnet keyset update)."
  echo "Current value: $current"
  exit 1
fi

if $FORCE && [[ -n "$current" && "$current" != REPLACE_ME* ]]; then
  echo "WARNING: replacing existing DAS_RPC_SECRET_PATH — coordinate keyset update with Blessnet ops."
fi

if grep -q '^DAS_RPC_SECRET_PATH=' "$NETWORK_ENV"; then
  sed -i "s/^DAS_RPC_SECRET_PATH=.*/DAS_RPC_SECRET_PATH=${SECRET}/" "$NETWORK_ENV"
else
  echo "DAS_RPC_SECRET_PATH=${SECRET}" >>"$NETWORK_ENV"
fi

chmod 600 "$NETWORK_ENV" 2>/dev/null || true

echo "Updated env/das.network.env"
echo "DAS_RPC_SECRET_PATH=${SECRET}"
echo "RPC URL (after nginx): https://\${DAS_DOMAIN}/rpc/${SECRET}"
