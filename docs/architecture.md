# Committee Node Deployment Blueprint

This document defines a clean way to distribute validator/DAS runtime to external committee members.

Goal: committee node runners should only provide their own keys + endpoints, while all runtime logic ships in pinned images and versioned templates.

## Design Principles

- **Immutable runtime**: distribute signed/versioned images, not ad-hoc scripts.
- **Runtime secrets only**: never bake private keys into images or git.
- **Small configuration surface**: runners fill env files and run one install command.
- **Deterministic upgrades**: pin image digests and publish a migration note per release.
- **Clear rollback**: every upgrade has a one-command rollback path.

## Recommended Layout

```text
committee-node/
  VERSION
  README.md
  CHANGELOG.md
  compose.yaml
  env/
    das.env.example
    validator.env.example
  scripts/
    install.sh
    validate-env.sh
    doctor.sh
    upgrade.sh
    rollback.sh
  systemd/
    blessnet-committee-node.service
  checks/
    smoke.sh
```

Starter scaffold in this repo:

- `committee-node/`

## Image Strategy

Publish two runtime images per release:

- `ghcr.io/<org>/blessnet-das:<version>`
- `ghcr.io/<org>/blessnet-validator:<version>`

Also publish digest-pinned references and use those in `compose.yaml`:

```yaml
services:
  arbitrum-das:
    image: ghcr.io/<org>/blessnet-das@sha256:<digest>
  validator:
    image: ghcr.io/<org>/blessnet-validator@sha256:<digest>
```

Current starter deployment uses `DAS_IMAGE` and `VALIDATOR_IMAGE` env vars pointing at pinned `offchainlabs/nitro-node` digests instead.

## Committee Node Inputs (Only)

Runners should populate only:

- `VALIDATOR_PRIVATE_KEY`
- DAS BLS key files (`das_bls`, `das_bls.pub`)
- `PARENT_CHAIN_RPC`
- `PARENT_CHAIN_BEACON_RPC` (for Sepolia/Ethereum blobs)
- `SEQUENCER_FEED_URL` (externally reachable)
- `ROLLUP_ADDRESS`, `CHAIN_ID`, `PARENT_CHAIN_ID`

Everything else should have sane defaults in templates.

## Example env Templates

### `env/das.env.example`

```bash
# Required
CHAIN_NAME=Blessnet
CHAIN_ID=45513
PARENT_CHAIN_ID=1
ROLLUP_ADDRESS=0xREPLACE_ME

# RPC
PARENT_CHAIN_RPC=https://REPLACE_ME
PARENT_CHAIN_BEACON_RPC=https://REPLACE_ME

# DAS
DAS_RPC_HOST=0.0.0.0
DAS_RPC_PORT=9876
DAS_REST_HOST=0.0.0.0
DAS_REST_PORT=9877

# Paths
DAS_DATA_DIR=/mnt/das_data
BLS_KEY_DIR=/mnt/das_data/bls_keys
```

### `env/validator.env.example`

```bash
# Required
VALIDATOR_PRIVATE_KEY=0xREPLACE_ME
ROLLUP_ADDRESS=0xREPLACE_ME
CHAIN_ID=45513
PARENT_CHAIN_ID=1

# RPC
PARENT_CHAIN_RPC=https://REPLACE_ME
PARENT_CHAIN_BEACON_RPC=https://REPLACE_ME

# Feed + forwarding
SEQUENCER_FEED_URL=ws://REPLACE_ME:9642
SEQUENCER_FORWARDING_TARGET=https://REPLACE_ME/rpc

# Staker behavior
ASSERTION_INTERVAL=0h15m0s
ENABLE_FAST_CONFIRMATION=true
```

## `compose.yaml` Conventions

- Use `${VAR:?missing VAR}` for required variables.
- Keep DAS and validator in separate services (even if co-hosted).
- Add CPU/memory limits to avoid validator starving DAS.
- Use explicit healthchecks for both services.

## Installer Flow (`scripts/install.sh`)

Recommended steps:

1. Verify Docker/Compose versions.
2. Validate env files via `validate-env.sh`.
3. Create data directories + permissions.
4. Pull pinned images.
5. `docker compose config` preflight.
6. Start services.
7. Run `doctor.sh`.

`install.sh` should fail fast and print actionable errors.

## Environment Validator (`scripts/validate-env.sh`)

Check:

- required vars present
- `0x`-format keys/addresses
- reachable RPC URLs
- feed URL not `.svc.cluster.local` for external hosts
- `PARENT_CHAIN_BEACON_RPC` set when required

## Runtime Doctor (`scripts/doctor.sh`)

Return non-zero on failure. Include:

- DAS `das_healthCheck`
- DAS REST `/health`
- validator `eth_syncing`
- parent RPC head/finalized queries
- gas balance for validator address

## Upgrade/Rollback

### Upgrade (`scripts/upgrade.sh`)

1. Backup current env + compose + image digests.
2. Pull new pinned images.
3. Recreate services one-by-one (DAS then validator).
4. Run smoke checks.

### Rollback (`scripts/rollback.sh`)

1. Restore previous digest-pinned compose.
2. Recreate services with previous images.
3. Run smoke checks.

## Security Requirements for External Committee Members

- non-root host user
- SSH key auth only
- firewall allowlist
- secrets file perms (`chmod 600`)
- no keys in shell history
- no keys in git

## Recommended Topology

For production-like operations:

- DAS and validator on separate hosts/VMs
- optional second validator signer on separate host
- independent RPC providers where possible

This lowers blast radius and makes fast-confirm committee behavior more reliable.

## Handoff Checklist

Before sharing the deployment:

- [ ] `README.md` has copy/paste install path
- [ ] env examples contain no real secrets
- [ ] images pinned by digest
- [ ] `doctor.sh` passes in a fresh test deploy
- [ ] upgrade + rollback tested once
- [ ] release notes include known pitfalls
