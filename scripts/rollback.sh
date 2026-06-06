#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="$ROOT_DIR/.backup"

if [[ ! -d "$BACKUP_ROOT" ]]; then
  echo "No backup directory found at $BACKUP_ROOT"
  exit 1
fi

LATEST_BACKUP="$(ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | head -n1 || true)"
if [[ -z "$LATEST_BACKUP" ]]; then
  echo "No backup snapshots found in $BACKUP_ROOT"
  exit 1
fi

echo "Restoring from $LATEST_BACKUP"
cp "$LATEST_BACKUP/compose.yaml" "$ROOT_DIR/compose.yaml"
cp "$LATEST_BACKUP/das.env" "$ROOT_DIR/env/das.env"
cp "$LATEST_BACKUP/validator.env" "$ROOT_DIR/env/validator.env"

cd "$ROOT_DIR"
docker compose --env-file env/das.env --env-file env/validator.env up -d

./scripts/doctor.sh
echo "Rollback complete."
