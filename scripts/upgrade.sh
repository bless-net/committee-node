#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$ROOT_DIR/.backup/$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp "$ROOT_DIR/compose.yaml" "$BACKUP_DIR/compose.yaml"
cp "$ROOT_DIR/env/das.env" "$BACKUP_DIR/das.env"
cp "$ROOT_DIR/env/validator.env" "$BACKUP_DIR/validator.env"

echo "Backed up current config to $BACKUP_DIR"

cd "$ROOT_DIR"
./scripts/validate-env.sh

docker compose --env-file env/das.env --env-file env/validator.env pull
docker compose --env-file env/das.env --env-file env/validator.env up -d

./scripts/doctor.sh
echo "Upgrade complete."
