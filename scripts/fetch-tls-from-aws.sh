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

AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ -n "${COMMITTEE_PROFILE:-}" ]]; then
  case "$COMMITTEE_PROFILE" in
    mainnet)
      AWS_TLS_CRT_SECRET="${AWS_TLS_CRT_SECRET:-blessnet/mainnet/tls/wildcard-crt}"
      AWS_TLS_KEY_SECRET="${AWS_TLS_KEY_SECRET:-blessnet/mainnet/tls/wildcard-key}"
      ;;
    testnet)
      AWS_TLS_CRT_SECRET="${AWS_TLS_CRT_SECRET:-blessnet/testnet/tls/wildcard-crt}"
      AWS_TLS_KEY_SECRET="${AWS_TLS_KEY_SECRET:-blessnet/testnet/tls/wildcard-key}"
      ;;
    *)
      echo "COMMITTEE_PROFILE must be mainnet or testnet (got: $COMMITTEE_PROFILE)"
      exit 1
      ;;
  esac
fi

for var in DAS_TLS_CERT DAS_TLS_KEY AWS_TLS_CRT_SECRET AWS_TLS_KEY_SECRET; do
  if [[ -z "${!var:-}" || "${!var}" == REPLACE_ME* ]]; then
    echo "Set $var in env/das.network.env (or set COMMITTEE_PROFILE=mainnet|testnet)"
    exit 1
  fi
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found — install awscli on this host"
  exit 1
fi

fetch_secret() {
  local secret_id="$1"
  aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$secret_id" \
    --query SecretString \
    --output text
}

TMP_CRT="$(mktemp)"
TMP_KEY="$(mktemp)"
trap 'rm -f "$TMP_CRT" "$TMP_KEY"' EXIT

echo "Fetching $AWS_TLS_CRT_SECRET (region $AWS_REGION)..."
fetch_secret "$AWS_TLS_CRT_SECRET" >"$TMP_CRT"
echo "Fetching $AWS_TLS_KEY_SECRET..."
fetch_secret "$AWS_TLS_KEY_SECRET" >"$TMP_KEY"

openssl x509 -in "$TMP_CRT" -noout >/dev/null
openssl rsa -in "$TMP_KEY" -check -noout >/dev/null 2>&1 || \
  openssl ec -in "$TMP_KEY" -check -noout >/dev/null

sudo install -d -m 755 "$(dirname "$DAS_TLS_CERT")" "$(dirname "$DAS_TLS_KEY")"
sudo install -m 644 "$TMP_CRT" "$DAS_TLS_CERT"
sudo install -m 600 "$TMP_KEY" "$DAS_TLS_KEY"

echo "Installed TLS material:"
echo "  $DAS_TLS_CERT"
echo "  $DAS_TLS_KEY"
openssl x509 -in "$DAS_TLS_CERT" -noout -subject -dates
