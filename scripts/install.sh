#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/validate-env.sh

mkdir -p bls_keys data validator-data
chmod 700 bls_keys

echo "Preflighting compose config..."
docker compose --env-file env/das.env --env-file env/validator.env config >/dev/null

echo "Pulling images..."
docker compose --env-file env/das.env --env-file env/validator.env pull

echo "Starting services..."
docker compose --env-file env/das.env --env-file env/validator.env up -d

echo "Current service status:"
docker compose --env-file env/das.env --env-file env/validator.env ps

echo "Running health checks..."
./scripts/doctor.sh

echo "Install complete."
