# Blessnet Committee Node

Docker Compose deployment for a co-hosted DAS + Nitro validator (one fast-confirm committee member).

A committee node runs both:

- `arbitrum-das` (standalone DAS), and
- `validator` (Nitro staker with fast-confirm flag enabled).

Production-like setups may split DAS and validator across separate hosts using the same deployment.

## Host Requirements

Use a fresh **Ubuntu 22.04 or 24.04** host (these instructions target Ubuntu on DigitalOcean; other providers work if you supply equivalent storage).

Minimum hardware for co-hosted DAS + validator:

- **Recommended**: 4 vCPU, 16 GiB RAM
- **Minimum**: 2 vCPU, 8 GiB RAM

Storage (Blessnet mainnet starting points):

| Path | Purpose | Where it lives | Size |
|------|---------|----------------|------|
| `data/` | DAS cache and file storage | Block volume → `/mnt/das-data` | 50–100 GB |
| `validator-data/` | Nitro validator chain DB | Block volume → `/mnt/validator-data` | 100–200 GB |
| `bls_keys/` | DAS BLS keypair (sensitive) | Droplet root disk | negligible |

The droplet root disk only needs room for the OS, Docker, and this git checkout — **not** for chain data. Attach two separate Block Storage volumes at droplet creation (see [Setup](#setup-follow-in-order)).

Required software (installed in [step 3](#3-install-host-software)):

| Package | Purpose |
|---------|---------|
| Docker Engine 24+ | Runs DAS and validator containers |
| Docker Compose v2 plugin | `docker compose` commands used by this repo |
| `git` | Clone this repository |
| `curl`, `jq`, `make` | Health checks and Makefile targets |
| `bash` | Install/upgrade scripts |

Production-like setups should run DAS and validator on **separate hosts**. If you keep them co-hosted in production, use at least 4 vCPU and 16 GiB RAM with both volumes above attached.

## Setup (follow in order)

Work through these steps on a **new** server before running any committee-node containers.

### 1. Create droplet and attach Block Storage volumes

In the [DigitalOcean control panel](https://cloud.digitalocean.com/droplets/new):

1. **Choose an image**: Ubuntu 24.04 LTS (or 22.04 LTS)
2. **Choose a plan**: at least 4 vCPU / 16 GiB RAM recommended
3. **Add block storage volumes** (same region as the droplet — attach them now, not later):
   - `blessnet-das-data` — 50–100 GB
   - `blessnet-validator-data` — 100–200 GB
4. **Create the droplet** and note its public IP

Alternatively, with [`doctl`](https://docs.digitalocean.com/reference/doctl/) (replace region and size as needed):

```bash
doctl compute droplet create blessnet-committee-node \
  --region nyc3 \
  --size s-4vcpu-16gb \
  --image ubuntu-24-04-x64 \
  --ssh-keys <your-ssh-key-fingerprint>

doctl compute volume create blessnet-das-data --region nyc3 --size 100GiB
doctl compute volume create blessnet-validator-data --region nyc3 --size 200GiB
doctl compute volume attach blessnet-das-data <droplet-id>
doctl compute volume attach blessnet-validator-data <droplet-id>
```

SSH in as root or your deploy user:

```bash
ssh root@<droplet-ip>
```

### 2. Format and mount volumes

Do this **immediately after first login**, before installing Docker or cloning this repo. The volumes attached in step 1 appear as extra block devices — confirm with:

```bash
lsblk -f
```

Format each volume once (use the `/dev/disk/by-id/scsi-0DO_Volume_*` paths from `lsblk` — do **not** format the root disk):

```bash
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

Both mount points should show the expected volume sizes and be empty.

### 3. Install host software

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl git jq make
```

Install Docker Engine and the Compose plugin from Docker's official apt repository (not the older `docker.io` package):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and back in (or run `newgrp docker`), then verify:

```bash
docker --version          # expect 24.x or newer
docker compose version    # expect Compose v2.x
docker run --rm hello-world
```

### 4. Clone the repository and wire storage

`compose.yaml` bind-mounts `./data` and `./validator-data`. Point those at the volumes mounted in step 2:

```bash
git clone https://github.com/bless-net/committee-node.git
cd committee-node
mkdir -p bls_keys
ln -s /mnt/das-data data
ln -s /mnt/validator-data validator-data
ls -la data validator-data    # should resolve to /mnt/*
```

`bls_keys/` stays on the root disk — it is small and sensitive; back it up separately from the bulk data volumes.

### 5. Configure environment and keys

Copy the example templates — do **not** edit the `.example` files in place:

```bash
cp env/das.env.example env/das.env
cp env/validator.env.example env/validator.env
```

Edit both files and replace every `REPLACE_ME` value with your Blessnet mainnet endpoints, contract addresses, and keys.

You must also provide:

- DAS BLS keypair at `./bls_keys/das_bls` and `./bls_keys/das_bls.pub`
- validator private key as `VALIDATOR_PRIVATE_KEY` in `env/validator.env`

Set key permissions:

```bash
chmod 700 bls_keys
chmod 600 bls_keys/das_bls bls_keys/das_bls.pub
```

### 6. Start and verify

```bash
chmod +x scripts/*.sh checks/*.sh
make validate
make render
make install
make doctor
```

`make install` pulls pinned images and starts `arbitrum-das` and `validator`. `make doctor` checks service health and runtime validator flags — it does **not** prove on-chain fast-confirm movement; use [Prove Fast Confirmations](#prove-fast-confirmations) for that.

### Non-DigitalOcean hosts

If you are not on DigitalOcean, provision two separate disks with the sizes above, then follow [step 2](#2-format-and-mount-volumes) to format and mount them at `/mnt/das-data` and `/mnt/validator-data` before continuing with [step 3](#3-install-host-software).

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
