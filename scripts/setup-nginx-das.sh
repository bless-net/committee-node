#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NETWORK_ENV="$ROOT_DIR/env/das.network.env"
if [[ ! -f "$NETWORK_ENV" ]]; then
  echo "Missing $NETWORK_ENV — copy from env/das.network.env.example"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$NETWORK_ENV"
set +a

for var in DAS_DOMAIN DAS_RPC_SECRET_PATH DAS_TLS_CERT DAS_TLS_KEY; do
  if [[ -z "${!var:-}" || "${!var}" == REPLACE_ME* ]]; then
    echo "Set $var in env/das.network.env"
    exit 1
  fi
done

if [[ ! -f "$DAS_TLS_CERT" || ! -f "$DAS_TLS_KEY" ]]; then
  echo "TLS files not found:"
  echo "  DAS_TLS_CERT=$DAS_TLS_CERT"
  echo "  DAS_TLS_KEY=$DAS_TLS_KEY"
  exit 1
fi

DEST="/etc/nginx/sites-available/arbitrum-das.conf"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

sed \
  -e "s/DAS_DOMAIN/${DAS_DOMAIN//\//\\/}/g" \
  -e "s/DAS_RPC_SECRET_PATH/${DAS_RPC_SECRET_PATH//\//\\/}/g" \
  -e "s|DAS_TLS_CERT|${DAS_TLS_CERT}|g" \
  -e "s|DAS_TLS_KEY|${DAS_TLS_KEY}|g" \
  "$ROOT_DIR/nginx/arbitrum-das.conf.example" >"$TMP"

sudo cp "$TMP" "$DEST"
sudo ln -sf "$DEST" /etc/nginx/sites-enabled/arbitrum-das.conf
sudo nginx -t
sudo systemctl reload nginx

echo "Installed $DEST"
echo "DAS REST URL: https://${DAS_DOMAIN}/rest"
echo "DAS RPC URL:  https://${DAS_DOMAIN}/rpc/${DAS_RPC_SECRET_PATH}"
