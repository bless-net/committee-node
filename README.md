# Blessnet Committee Node

Docker Compose deployment for a co-hosted DAS + Nitro validator (one fast-confirm committee member).

A committee node runs both:

- `arbitrum-das` (standalone DAS), and
- `validator` (Nitro staker with fast-confirm flag enabled).

Production-like setups may split DAS and validator across separate hosts using the same deployment.

## Host Requirements

Use a fresh **Ubuntu 22.04 or 24.04** VM or bare-metal host (other modern Linux distros may work, but these instructions target Ubuntu).

Minimum hardware for co-hosted DAS + validator:

- **Recommended**: 4 vCPU, 16 GiB RAM, 200+ GB SSD
- **Minimum**: 2 vCPU, 8 GiB RAM, 120 GB SSD

Required software:

| Package | Purpose |
|---------|---------|
| Docker Engine 24+ | Runs DAS and validator containers |
| Docker Compose v2 plugin | `docker compose` commands used by this repo |
| `git` | Clone this repository |
| `curl`, `jq`, `make` | Health checks and Makefile targets |
| `bash` | Install/upgrade scripts |

## Install Host Software (Ubuntu)

Run these steps on the host **before** configuring the committee node.

### 1. Update the system

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl git jq make
```

### 2. Install Docker Engine and Compose plugin

Use Docker's official apt repository (not the older `docker.io` package from Ubuntu):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Enable Docker on boot and start it now:

```bash
sudo systemctl enable --now docker
```

Allow your deploy user to run Docker without `sudo` (log out and back in after this):

```bash
sudo usermod -aG docker "$USER"
```

### 3. Verify the install

```bash
docker --version          # expect 24.x or newer
docker compose version    # expect Compose v2.x
git --version
jq --version
make --version
docker run --rm hello-world
```

If `docker run` fails with a permission error, your shell session has not picked up the `docker` group yet — log out/in or run `newgrp docker`, then retry.

## Storage Layout

The deployment expects this on the host:

```text
committee-node/
  bls_keys/         # DAS BLS keypair (sensitive; keep on root disk)
    das_bls
    das_bls.pub
  data/             # DAS local cache/file storage  → use a dedicated volume
  validator-data/   # Nitro validator DB/state       → use a dedicated volume
```

`compose.yaml` bind-mounts `./data` and `./validator-data` into the containers. Do **not** let these grow on the droplet root disk — attach separate block volumes and point these directories at them (see below).

Suggested sizing for Blessnet mainnet (starting points):

| Path | Purpose | Suggested volume size |
|------|---------|----------------------|
| `data/` | DAS cache and file storage | 50–100 GB |
| `validator-data/` | Nitro validator chain DB | 100–200 GB |

Production-like setups should run DAS and validator on **separate hosts**. If you keep them co-hosted in production, use at least 4 vCPU, 16 GiB RAM, and attach both volumes above.

### DigitalOcean Block Storage (recommended)

On DigitalOcean, create **two Block Storage volumes** in the **same region** as your droplet — one for DAS, one for the validator. Keep the droplet root disk for the OS, Docker, this git checkout, and `bls_keys/` only.

| Volume name (example) | Size | Mount on host | Repo path |
|-----------------------|------|---------------|-----------|
| `blessnet-das-data` | 50–100 GB | `/mnt/das-data` | `data/` |
| `blessnet-validator-data` | 100–200 GB | `/mnt/validator-data` | `validator-data/` |

#### 1. Create and attach volumes

In the [DigitalOcean control panel](https://cloud.digitalocean.com/volumes):

1. **Create → Volumes → Block Storage**
2. Create `blessnet-das-data` (50–100 GB) and `blessnet-validator-data` (100–200 GB) in the droplet's region
3. Attach both volumes to your committee-node droplet

Alternatively, with [`doctl`](https://docs.digitalocean.com/reference/doctl/) (replace names, region, and droplet ID):

```bash
doctl compute volume create blessnet-das-data --region nyc3 --size 100GiB
doctl compute volume create blessnet-validator-data --region nyc3 --size 200GiB
doctl compute volume attach blessnet-das-data <droplet-id>
doctl compute volume attach blessnet-validator-data <droplet-id>
```

#### 2. Format and mount (Ubuntu)

On the droplet, identify the new devices (names vary; `lsblk` is the reliable check):

```bash
lsblk -f
```

Format each volume once (use the `/dev/disk/by-id/scsi-0DO_Volume_*` path from `lsblk` — do **not** format the root disk):

```bash
# Replace the device paths below with your volume IDs from lsblk
DAS_DEV=/dev/disk/by-id/scsi-0DO_Volume_blessnet-das-data
VALIDATOR_DEV=/dev/disk/by-id/scsi-0DO_Volume_blessnet-validator-data

sudo mkfs.ext4 -F "$DAS_DEV"
sudo mkfs.ext4 -F "$VALIDATOR_DEV"

sudo mkdir -p /mnt/das-data /mnt/validator-data
```

Add persistent mounts (replace UUIDs with output from `sudo blkid`):

```bash
sudo tee -a /etc/fstab <<'EOF'
UUID=<das-data-uuid>       /mnt/das-data       ext4 defaults,nofail,discard 0 2
UUID=<validator-data-uuid> /mnt/validator-data ext4 defaults,nofail,discard 0 2
EOF

sudo mount -a
df -h /mnt/das-data /mnt/validator-data
```

#### 3. Wire volumes into this repository

After cloning the repo (see [Quick Start](#quick-start)), link the repo paths to the mounted volumes:

```bash
cd committee-node
mkdir -p bls_keys
rm -rf data validator-data
ln -s /mnt/das-data data
ln -s /mnt/validator-data validator-data
```

Confirm Docker will see the mounts:

```bash
ls -la data validator-data
```

`bls_keys/` stays on the root disk — it is small and sensitive; back it up separately from the bulk data volumes.

## What You Provide

Fill values in:

- `env/das.env`
- `env/validator.env`

from the example templates in `env/*.example`.

Required secret inputs:

- DAS BLS keypair (`./bls_keys/das_bls`, `./bls_keys/das_bls.pub`)
- validator private key (`VALIDATOR_PRIVATE_KEY`)

## Quick Start

Complete [Install Host Software](#install-host-software-ubuntu) first. If you are on DigitalOcean, also complete [DigitalOcean Block Storage](#digitalocean-block-storage-recommended) before starting containers.

### 1. Clone this repository

```bash
git clone https://github.com/bless-net/committee-node.git
cd committee-node
```

If using DO Block Storage, wire the mounted volumes now:

```bash
mkdir -p bls_keys
rm -rf data validator-data
ln -s /mnt/das-data data
ln -s /mnt/validator-data validator-data
```

Otherwise create local data directories on a disk with enough free space:

```bash
mkdir -p bls_keys data validator-data
```

### 2. Create runtime env files

Copy the example templates — do **not** edit the `.example` files in place:

```bash
cp env/das.env.example env/das.env
cp env/validator.env.example env/validator.env
```

Edit both files and replace every `REPLACE_ME` value with your Blessnet mainnet endpoints, contract addresses, and keys.

Install your DAS BLS keypair and set permissions:

```bash
# place das_bls and das_bls.pub in bls_keys/ (provided separately)
chmod 700 bls_keys
chmod 600 bls_keys/das_bls bls_keys/das_bls.pub
```

### 3. Validate configuration

```bash
chmod +x scripts/*.sh checks/*.sh
make validate
make render
```

`make validate` runs `./scripts/validate-env.sh`. `make render` checks that Compose can render with your env files.

### 4. Start the node

```bash
make install
```

This pulls pinned images and starts `arbitrum-das` and `validator`.

### 5. Run health checks

```bash
make doctor
```

`doctor.sh` validates service health plus runtime validator flags. It does **not** prove on-chain fast-confirm movement — use [Prove Fast Confirmations](#prove-fast-confirmations) for that.

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
