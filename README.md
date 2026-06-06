# Blessnet Committee Node

Docker Compose deployment for a co-hosted DAS + Nitro validator (one fast-confirm committee member).

A committee node runs both:

- `arbitrum-das` (standalone DAS), and
- `validator` (Nitro staker with fast-confirm flag enabled).

Production-like setups may split DAS and validator across separate hosts using the same deployment.

## Host Prerequisites

Recommended host baseline (co-hosted DAS + validator):

- Ubuntu 22.04+ (or equivalent modern Linux)
- Docker Engine 24+
- Docker Compose v2 plugin
- `bash`, `curl`, `jq`, `make`

Quick checks:

```bash
docker --version
docker compose version
jq --version
make --version
```

## Storage Layout

The deployment expects this on the host:

```text
committee-node/
  bls_keys/         # DAS BLS keypair (sensitive)
    das_bls
    das_bls.pub
  data/             # DAS local cache/file storage
  validator-data/   # Nitro validator DB/state
```

Recommended mount strategy:

- Keep `committee-node/` on a dedicated data disk (not tiny root disk), or
- Bind `data/` and `validator-data/` to dedicated volumes.

Suggested sizing (starting points):

- `data/` (DAS): 20-50 GB testnet, larger for long retention
- `validator-data/`: 50-100 GB testnet, larger for long-lived networks

## Minimum Specs

For co-hosted DAS + validator:

- **Testnet minimum**: 2 vCPU, 8 GiB RAM, 120 GB SSD
- **Testnet recommended**: 4 vCPU, 16 GiB RAM, 200+ GB SSD
- **Production-like recommended**: separate DAS and validator hosts

If you keep co-hosted in production-like environments, use at least:

- 4 vCPU, 16 GiB RAM, 300+ GB SSD

## What You Provide

Fill values in:

- `env/das.env`
- `env/validator.env`

from the example templates in `env/*.example`.

Required secret inputs:

- DAS BLS keypair (`./bls_keys/das_bls`, `./bls_keys/das_bls.pub`)
- validator private key (`VALIDATOR_PRIVATE_KEY`)

## Quick Start

1. Copy env templates:

```bash
cp env/das.env.example env/das.env
cp env/validator.env.example env/validator.env
```

2. Edit env files and replace all `REPLACE_ME` values.

3. Create required directories:

```bash
mkdir -p bls_keys data validator-data
chmod 700 bls_keys
```

4. Make scripts executable:

```bash
chmod +x scripts/*.sh
```

5. Validate inputs and render config:

```bash
./scripts/validate-env.sh
docker compose --env-file env/das.env --env-file env/validator.env config >/dev/null
```

Equivalent Makefile commands:

```bash
make validate
make render
```

6. Install/start:

```bash
./scripts/install.sh
```

7. Run health checks:

```bash
./scripts/doctor.sh
```

`doctor.sh` validates service health plus runtime validator flags. It does **not** prove on-chain fast-confirm movement.
Use the proof check below for that.

## Runtime Operations

- Upgrade: `./scripts/upgrade.sh`
- Rollback: `./scripts/rollback.sh`

Makefile equivalents:

```bash
make upgrade
make rollback
make doctor
```

## Prove Fast Confirmations

To verify confirmations are actually moving (not just configured), set `ROLLUP_ADDRESS` in `env/validator.env`, then run:

```bash
make prove-fast-confirm
```

What this does:

- samples L2 `eth_blockNumber` and rollup `latestConfirmed()`
- waits `FAST_CONFIRM_PROOF_WINDOW_SECONDS` (default `180`)
- fails if L2 blocks advance but `latestConfirmed` does not

Optional:

- set `CHAIN_RPC_URL` to a dedicated L2 RPC endpoint (otherwise `SEQUENCER_FORWARDING_TARGET` is used)
- tune `FAST_CONFIRM_PROOF_WINDOW_SECONDS` for lower/high traffic periods

## Notes

- Images are pinned by digest in env files. Update digests as part of release process.
- For external validator hosts, `SEQUENCER_FEED_URL` must be externally reachable.
- `PARENT_CHAIN_BEACON_RPC` is required for Ethereum/Sepolia blob reads.
- Keep private keys out of shell history and git.
