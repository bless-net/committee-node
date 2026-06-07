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

Required software (installed in [step 4](#4-install-host-software)):

| Package | Purpose |
|---------|---------|
| Docker Engine 24+ | Runs DAS and validator containers |
| Docker Compose v2 plugin | `docker compose` commands used by this repo |
| `git` | Clone this repository |
| `curl`, `jq`, `make` | Health checks and Makefile targets |
| `bash` | Install/upgrade scripts |

Production-like setups should run DAS and validator on **separate hosts**. If you keep them co-hosted in production, use at least 4 vCPU and 16 GiB RAM with both volumes above attached.

All day-to-day work runs as a **non-root operator user** with `sudo`. Root is only for initial bootstrap (steps 2.1–2.3).

## Setup (follow in order)

Work through these steps on a **new** server before running any committee-node containers.

Set these on your **local machine** before you start (used throughout):

```bash
export NODE_IP=<droplet-public-ip>
export ADMIN_SSH_KEY=~/.ssh/id_ed25519    # your admin private key
export OP_USER=<your-username>            # non-root operator, e.g. omnus
```

### 1. Create droplet and attach Block Storage volumes

In the [DigitalOcean control panel](https://cloud.digitalocean.com/droplets/new):

1. **Create → Droplets**
2. **Image:** Ubuntu LTS (22.04 or 24.04)
3. **Size:** at least 4 vCPU / 16 GiB RAM recommended (minimum 2 vCPU / 8 GiB RAM)
4. **Region:** same region as your other Blessnet infrastructure (e.g. `nyc3`)
5. **Add block storage volumes** (same region — attach them now, not later):
   - `blessnet-das-data` — 50–100 GB
   - `blessnet-validator-data` — 100–200 GB
6. **Authentication:** SSH keys only — add your admin public key; **do not** enable root password login
7. **Firewall (recommended):** create or attach a cloud firewall that allows **inbound SSH (`22/tcp`) only from your admin IP or VPN CIDR**
8. **Hostname:** `blessnet-mainnet-committee-node` (or `blessnet-testnet-committee-node` for testnet)
9. **Create the droplet** and set `NODE_IP` to its public IP

Alternatively, with [`doctl`](https://docs.digitalocean.com/reference/doctl/) (replace region, size, and SSH key fingerprint):

```bash
doctl compute droplet create blessnet-mainnet-committee-node \
  --region nyc3 \
  --size s-4vcpu-16gb \
  --image ubuntu-24-04-x64 \
  --ssh-keys <your-ssh-key-fingerprint>

doctl compute volume create blessnet-das-data --region nyc3 --size 100GiB
doctl compute volume create blessnet-validator-data --region nyc3 --size 200GiB
doctl compute volume attach blessnet-das-data <droplet-id>
doctl compute volume attach blessnet-validator-data <droplet-id>
```

### 2. Bootstrap access and harden the host

#### 2.1 First login (root, key-only)

```bash
ssh -i "$ADMIN_SSH_KEY" root@"${NODE_IP}"
```

Keep this root session open until **step 2.3** validates operator login in a second terminal.

#### 2.2 Create a non-root operator user (required)

Run **once as `root`**:

```bash
export OP_USER="${OP_USER:-omnus}"
adduser "$OP_USER"
usermod -aG sudo "$OP_USER"

install -d -m 700 "/home/$OP_USER/.ssh"
cp /root/.ssh/authorized_keys "/home/$OP_USER/.ssh/authorized_keys"
chown -R "$OP_USER:$OP_USER" "/home/$OP_USER/.ssh"
chmod 600 "/home/$OP_USER/.ssh/authorized_keys"
```

Validate in a **second terminal** before changing SSH settings (leave the root session open):

```bash
ssh -i "$ADMIN_SSH_KEY" "${OP_USER}@${NODE_IP}"
whoami    # expect: your OP_USER
sudo -v   # expect: succeeds
groups    # expect: includes sudo
exit
```

If validation succeeds, **return to your original `root` session** for step 2.3. Keep that root session open until step 2.3 confirms operator login still works — then close root and use `"$OP_USER"` from step 2.4 onward.

#### 2.3 Harden SSH (required — disable root login and password auth)

Run as **`root`** (still in your original session) **only after** step 2.2 validation succeeds:

```bash
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

# Key-only auth; no root SSH
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

if grep -q '^#\?PubkeyAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi

sshd -t
systemctl reload ssh
```

Confirm operator login still works in another terminal:

```bash
ssh -i "$ADMIN_SSH_KEY" "${OP_USER}@${NODE_IP}"
```

Then **close the root session**. Do all further work as `"$OP_USER"`.

If you lock yourself out, use the DigitalOcean Droplet **Recovery Console** to fix `sshd_config` or temporarily re-enable access.

#### 2.4 Host hardening (automatic updates, fail2ban, firewall)

Run as your **operator user** with `sudo`:

```bash
ssh -i "$ADMIN_SSH_KEY" "${OP_USER}@${NODE_IP}"

# Automatic security updates
sudo apt update
sudo apt install -y unattended-upgrades apt-listchanges
sudo dpkg-reconfigure -plow unattended-upgrades

# fail2ban (edit jail.local, not jail.conf)
sudo apt install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo systemctl enable --now fail2ban
```

Add or update the `[sshd]` block in `/etc/fail2ban/jail.local` (`sudo nano /etc/fail2ban/jail.local`):

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
banaction = ufw
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 5
bantime = 1h
findtime = 10m
```

Add your admin IP or VPN CIDR to `ignoreip` so you do not ban yourself.

```bash
sudo fail2ban-client reload
sudo fail2ban-client status sshd

# UFW — allow SSH before enabling
sudo ufw allow OpenSSH
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

Committee-node services bind RPC to `127.0.0.1` by default (`env/*.example`), so inbound access beyond SSH is not required on this host.

### 3. Format and mount volumes

NOT REQUIRED IF FORMATTED AND MOUNTED AT CREATION (e.g. through digital ocean)

As your **operator user**, format and mount the block volumes attached in step 1. Do this before installing Docker or cloning this repo.

```bash
lsblk -f
```

Format each volume once (use the `/dev/disk/by-id/scsi-0DO_Volume_*` paths from `lsblk` — do **not** format the root filesystem disk):

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

#### Set volume ownership (required)

DigitalOcean block volumes mount as **`root:root`**. The Nitro containers run as UID **`1000`** (`user` in the image). If you skip this step, DAS and validator will crash with permission errors.

Use your **actual mount paths** (the paths you will use for `DAS_MOUNT` / `VALIDATOR_MOUNT` in step 5 — not the `data/` symlinks):

```bash
export DAS_MOUNT=/mnt/REPLACE_WITH_DAS_MOUNT
export VALIDATOR_MOUNT=/mnt/REPLACE_WITH_VALIDATOR_MOUNT

sudo chown -R 1000:1000 "$DAS_MOUNT" "$VALIDATOR_MOUNT"
```

Verify the **mount directories themselves** (not the symlinks — `ls -ld data` is not enough):

```bash
ls -ld "$DAS_MOUNT" "$VALIDATOR_MOUNT"
```

Both must show owner **`1000`**, not `root`. If they still show `root`, containers will not start.

### 4. Install host software

Still as your **operator user**:

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

### 5. Clone the repository and wire storage

`compose.yaml` bind-mounts `./data` and `./validator-data`. Point those at the volumes mounted in step 3:

```bash
git clone https://github.com/bless-net/committee-node.git
cd committee-node

# Replace with the mount points you used in step 3 (must exist before linking)
export DAS_MOUNT=/mnt/REPLACE_WITH_DAS_MOUNT
export VALIDATOR_MOUNT=/mnt/REPLACE_WITH_VALIDATOR_MOUNT

if [[ ! -d "$DAS_MOUNT" || ! -d "$VALIDATOR_MOUNT" ]]; then
  echo "Mount paths missing — set DAS_MOUNT and VALIDATOR_MOUNT to your step 3 paths"
else
  ln -s "$DAS_MOUNT" data
  ln -s "$VALIDATOR_MOUNT" validator-data
  ls -la data validator-data
fi
```

Example (if you mounted at the suggested paths in step 3):

```bash
export DAS_MOUNT=/mnt/das-data
export VALIDATOR_MOUNT=/mnt/validator-data
ln -s "$DAS_MOUNT" data
ln -s "$VALIDATOR_MOUNT" validator-data
```

`bls_keys/` is already in the clone (for your BLS keypair in step 6). It stays on the droplet root disk — small and sensitive; back it up separately from the bulk data volumes.

The `data/` and `validator-data/` symlinks point at your mount paths — ownership must be set on those targets in [Set volume ownership](#set-volume-ownership-required). After symlinking, confirm with `ls -ld "$DAS_MOUNT" "$VALIDATOR_MOUNT"`, not `ls -ld data` alone.

### 6. Configure environment and keys

Copy the example templates — do **not** edit the `.example` files in place:

```bash
cp env/das.env.example env/das.env
cp env/validator.env.example env/validator.env
```

Edit both files and replace every `REPLACE_ME` value with your Blessnet mainnet endpoints, contract addresses, and keys.

Set the validator private key as `VALIDATOR_PRIVATE_KEY` in `env/validator.env` — **64 hex characters, no `0x` prefix** (committee member key — not the same as the BLS key).

#### Generate the DAS BLS keypair

Each committee member needs a unique BLS keypair for the DAS to sign data-availability certificates. Generate it with Nitro's `datool` using the same pinned image as `DAS_IMAGE` in `env/das.env`:

```bash
set -a
source env/das.env
set +a

docker run --rm -v "$(pwd)/bls_keys:/data/keys" --entrypoint datool \
  "$DAS_IMAGE" keygen --dir /data/keys

sudo chown -R 1000:1000 bls_keys
chmod 700 bls_keys
chmod 600 bls_keys/das_bls bls_keys/das_bls.pub
ls -la bls_keys/das_bls bls_keys/das_bls.pub
```

This creates `./bls_keys/das_bls` (private) and `./bls_keys/das_bls.pub` (public). **Back up the private key securely** — treat it like any other signing key.

If the files already exist, skip `keygen` and only run the `chmod` lines.

Before your DAS can serve on the committee, the **base64-encoded public key** from `das_bls.pub` must be registered in the chain's DAC keyset (on-chain `SequencerInbox` keyset update). That step is done outside this repo as part of Blessnet chain/DAC operations — coordinate with whoever manages the rollup deployment.

#### Set container data permissions (required before first start)

Nitro containers run as UID **`1000`**. Re-apply ownership before starting — especially after `keygen`, which writes keys as your login user.

**Use your mount paths and `bls_keys/` directly** — `chown -R data` does not reliably update symlink targets:

```bash
sudo chown -R 1000:1000 "$DAS_MOUNT" "$VALIDATOR_MOUNT" bls_keys
ls -ld "$DAS_MOUNT" "$VALIDATOR_MOUNT" bls_keys
```

All three must show owner **`1000`**, not `root` or your login user.

### 7. Start and verify

```bash
chmod +x scripts/*.sh checks/*.sh
make validate
make render
make install
make doctor
```

`make install` pulls pinned images and starts `arbitrum-das` and `validator`. `make doctor` checks service health and runtime validator flags — it does **not** prove on-chain fast-confirm movement; use [Prove Fast Confirmations](#prove-fast-confirmations) for that.

### Non-DigitalOcean hosts

If you are not on DigitalOcean, follow the same bootstrap and hardening pattern (steps 2.1–2.4), provision two separate disks with the sizes above, then complete [step 3](#3-format-and-mount-volumes) before continuing.

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
