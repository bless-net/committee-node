# Blessnet Committee Node

Docker Compose deployment for a co-hosted DAS + Nitro validator (one fast-confirm committee member).

A committee node runs both:

- `arbitrum-das` (standalone DAS), and
- `validator` (Nitro staker with **Defensive** strategy and fast-confirm enabled).

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

DAS binds to `127.0.0.1` by default (`env/*.example`). That is enough for a local `make doctor` run. **Committee membership requires exposing DAS over HTTPS** — see [step 8](#8-expose-das-endpoints-committee-networking).

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

Both must show owner **`1000`** (or the user name associated with this user), not `root`. If they still show `root`, containers will not start.

### 4. Install host software

Still as your **operator user**:

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl git jq make
```

Keep the local version of your ssh config.

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

Edit both files and replace every `REPLACE_ME` value with your Blessnet endpoints, contract addresses, and keys.

**`env/validator.env` (required)**

| Variable | Source |
|----------|--------|
| `CHAIN_NAME` | Must match `"chain-name"` inside `CHAIN_INFO_JSON` exactly (e.g. `Blessnet`) |
| `CHAIN_INFO_JSON` | **Full** Orbit chain info JSON from Blessnet deploy output — not just `chain-id` / `parent-chain-id`. A minimal stub causes `unsupported chain name` at validator start. |
| `VALIDATOR_PRIVATE_KEY` | Committee staker key — **64 hex characters, no `0x` prefix** |
| Other `REPLACE_ME` fields | Blessnet RPC, feed, forwarding target, etc. |

**`env/das.env` (required)**

| Variable | Source |
|----------|--------|
| `DAS_REST_AGGREGATOR_URLS` | Comma-separated **sibling** committee REST bases from Blessnet ops (each ends with `/rest`). See [step 9](#9-das-peer-backfill). |
| `PARENT_CHAIN_RPC`, `SEQUENCER_INBOX_ADDRESS` | Blessnet parent-chain values |

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

Before your DAS can serve on the committee, coordinate with Blessnet ops ([handoff doc](docs/blessnet-ops-handoff.md)):

- **Request:** full `CHAIN_INFO_JSON`, sibling `DAS_REST_AGGREGATOR_URLS` list, IAM key for TLS (if using AWS)
- **After step 8:** BLS public key, DAS RPC URL, DAS REST URL for keyset registration

#### Set container data permissions (required before first start)

Nitro containers run as UID **`1000`**. Re-apply ownership before starting — especially after `keygen`, which writes keys as your login user.

**Use your mount paths and `bls_keys/` directly** — `chown -R data` does not reliably update symlink targets:

```bash
sudo chown -R 1000:1000 "$DAS_MOUNT" "$VALIDATOR_MOUNT" bls_keys
ls -ld "$DAS_MOUNT" "$VALIDATOR_MOUNT" bls_keys
```

All three must show owner **`1000`**, not `root` or your login user.

### Setup order (steps 6–9)

| Step | What |
|------|------|
| **6** | `env/das.env`, `env/validator.env`, BLS keys — include `DAS_REST_AGGREGATOR_URLS` and full `CHAIN_INFO_JSON` |
| **7** | `make install` + `make doctor` (local health) |
| **8** | nginx + TLS; hand RPC/REST URLs to Blessnet for keyset |
| **9** | Confirm peer backfill if validator hits DAS 404s on inbox (upgrade path if you deployed before step 9 existed) |

### 7. Start and verify

```bash
chmod +x scripts/*.sh checks/*.sh
make validate
make render
make install
make doctor
```

`make install` pulls pinned images and starts `arbitrum-das` and `validator`. `make doctor` checks service health and runtime validator flags — it does **not** prove on-chain fast-confirm movement; use [Prove Fast Confirmations](#prove-fast-confirmations) for that.

If the validator later logs `Couldn't fetch DAS batch contents`, complete [step 9](#9-das-peer-backfill) (or the [upgrade section](#upgrading-existing-committee-nodes-peer-backfill) for nodes deployed before peer backfill was documented).

### 8. Expose DAS endpoints (committee networking)

`make doctor` only hits `127.0.0.1`. To participate in the DAC, Blessnet's Nitro nodes must reach your DAS over the URLs registered in the on-chain keyset.

| Endpoint | Internal port | Who needs it | How to expose |
|----------|---------------|--------------|---------------|
| **DAS RPC** | `9876` | Batch poster (`das_store`) | HTTPS **secret path** via nginx (out-of-band URL) |
| **DAS REST** | `9877` | Sequencer, fullnode, validator, batch-poster | HTTPS **`/rest/`** via nginx |

The co-hosted validator talks to DAS REST internally (`http://arbitrum-das:9877` in Docker). This step is for **external** callers only.

**Recommended mode:** keep `DAS_RPC_BIND=127.0.0.1` and `DAS_REST_BIND=127.0.0.1` in `env/das.env`. Expose both through **nginx on 443**. Do **not** publish `9876` or `9877` on the public internet.

This does **not** require Blessnet to provide stable Kubernetes egress IPs for firewall allowlisting. Security comes from TLS, a secret RPC path, and (for production) CDN/WAF in front of REST.

**Blessnet ops coordination** — keyset registration, connectivity tests, and copy-paste email templates: [docs/blessnet-ops-handoff.md](docs/blessnet-ops-handoff.md).

#### 8.1 Prerequisites

- DNS **A record** for this host (see below)
- `make doctor` passing on localhost
- Inbound **80** and **443** allowed (extend UFW and cloud firewall from step 2.4)

##### DNS A record — what points where

The A record is **not a URL**. It maps a **hostname** to this committee server’s **public IPv4 address** (the same IP you SSH to — `NODE_IP` from [step 1](#1-create-droplet-and-attach-block-storage-volumes)).

| DNS field | Value |
|-----------|--------|
| **Type** | `A` |
| **Name / host** | The subdomain you choose (e.g. `das-member` for `das-member.bless.net`) |
| **Value / points to** | This droplet’s **public IP** — not `https://…`, not a path, just the IP |
| **TTL** | Default is fine (e.g. 300–3600) |

**Examples**

| `DAS_DOMAIN` (in `env/das.network.env`) | A record name | Points to |
|----------------------------------------|---------------|-----------|
| `das-member.bless.net` (mainnet) | `das-member` in zone `bless.net` | `203.0.113.10` |
| `das-member.test.bless.net` (testnet) | `das-member` in zone `test.bless.net` | `203.0.113.10` |

Get this server’s public IP (on the droplet):

```bash
curl -4 -s ifconfig.me
```

Who creates the record depends on who hosts DNS for `bless.net` — often **Blessnet ops**, not the committee operator. Ask them to add the A record, or add it yourself if you control the zone.

Set `DAS_DOMAIN` in `env/das.network.env` to the **full hostname** (must match the cert wildcard: `*.bless.net` or `*.test.bless.net`).

Verify after DNS propagates (from your laptop or the droplet):

```bash
dig +short das-member.bless.net A
# must print your droplet public IP

curl -4 -s ifconfig.me   # on droplet — should match dig output
```

HTTPS URLs (`https://das-member.bless.net/rest`, etc.) come **after** nginx + TLS in step 8.4 — the A record only needs the IP.

#### 8.2 Record exposure settings

```bash
cp env/das.network.env.example env/das.network.env
chmod 600 env/das.network.env
make gen-das-rpc-secret-path
```

Edit `env/das.network.env`:

- `COMMITTEE_PROFILE` — `mainnet` or `testnet` (picks AWS wildcard secret names when you run `make fetch-tls-aws`; do not set `AWS_TLS_*` in this file)
- `DAS_DOMAIN` — public DNS under the wildcard (`das-member.bless.net` or `das-member.test.bless.net`)
- `DAS_TLS_CERT` / `DAS_TLS_KEY` — local PEM paths (defaults are fine; filled by `make fetch-tls-aws` or manual install)
- `DAS_RPC_SECRET_PATH` — set by `make gen-das-rpc-secret-path` (treat like a password; share RPC URL out-of-band only; use `--force` only with a keyset update)
- `AWS_PROFILE` — optional, only if you used a named `aws configure` profile

Confirm `env/das.env` keeps localhost binds:

```bash
DAS_RPC_BIND=127.0.0.1
DAS_REST_BIND=127.0.0.1
```

#### 8.3 Host and cloud firewall

Allow inbound **SSH (22)**, **HTTP (80)**, and **HTTPS (443)** only. Block **9876** and **9877** from the internet.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw deny 9876/tcp
sudo ufw deny 9877/tcp
sudo ufw status verbose
```

Mirror the same rules in your **cloud firewall** (DigitalOcean, etc.) if you use one.

Verify from another machine:

```bash
nc -vz das-member.example.com 443    # should succeed
nc -vz das-member.example.com 9876   # should fail
nc -vz das-member.example.com 9877   # should fail
```

#### 8.4 nginx and TLS

Install nginx if it is not already on the host:

```bash
sudo apt-get update
sudo apt-get install -y nginx
```

##### Option A — AWS Secrets Manager (Blessnet wildcard cert, recommended)

Complete **§8.2** first, then AWS-only steps in **[docs/tls-aws-secrets-manager.md](docs/tls-aws-secrets-manager.md)**:

```bash
make install-aws-cli    # Ubuntu 24.04 — no apt awscli package
aws configure           # IAM key from Blessnet ops; region us-east-1
make fetch-tls-aws
make setup-nginx-das
```

You do **not** run rollup §14.0 (ingress-nginx / External Secrets) on this host. After cert rotation: `make fetch-tls-aws` and `sudo systemctl reload nginx`.

##### Option B — Certificate files you install manually

```bash
sudo install -d -m 755 /etc/ssl/certs /etc/ssl/private
sudo install -m 644 /path/from/you/fullchain.pem /etc/ssl/certs/das-fullchain.pem
sudo install -m 600 /path/from/you/privkey.pem   /etc/ssl/private/das-privkey.pem
make setup-nginx-das
```

##### Option C — Let's Encrypt

```bash
sudo apt-get install -y certbot python3-certbot-nginx
set -a && source env/das.network.env && set +a
sudo certbot certonly --nginx -d "$DAS_DOMAIN"
# DAS_TLS_CERT=/etc/letsencrypt/live/$DAS_DOMAIN/fullchain.pem
# DAS_TLS_KEY=/etc/letsencrypt/live/$DAS_DOMAIN/privkey.pem
make setup-nginx-das
```

**Already using nginx for this subdomain?** Do not add a second `server` block. Copy the `location` blocks from `nginx/arbitrum-das.locations.example` into your existing `server { listen 443 ssl; server_name <DAS_DOMAIN>; ... }`. Substitute `DAS_RPC_SECRET_PATH`, then `sudo nginx -t && sudo systemctl reload nginx`.

#### 8.5 URLs to hand Blessnet

```bash
set -a
source env/das.network.env
set +a

export DAS_REST_PUBLIC_URL="https://${DAS_DOMAIN}/rest"
export DAS_RPC_PRIVATE_URL="https://${DAS_DOMAIN}/rpc/${DAS_RPC_SECRET_PATH}"

echo "DAS REST URL (public): $DAS_REST_PUBLIC_URL"
echo "DAS RPC URL (private): $DAS_RPC_PRIVATE_URL"
echo "BLS public key:"
cat bls_keys/das_bls.pub
```

- **REST** — register `https://<domain>/rest` in Blessnet's `DAS_REST_AGGREGATOR_URLS` and keyset.
- **RPC** — register the full secret-path URL in the keyset; share only out-of-band.
- Do not rotate the RPC secret path without coordinating a keyset update.

See [docs/blessnet-ops-handoff.md](docs/blessnet-ops-handoff.md) for the email template.

#### 8.6 Validate endpoints

Local DAS (unchanged):

```bash
curl -sS -X POST "http://127.0.0.1:9876" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"das_healthCheck","params":[]}'
curl -I "http://127.0.0.1:9877/health"
```

Public paths through nginx (from any machine):

```bash
set -a
source env/das.network.env
set +a

curl -I "https://${DAS_DOMAIN}/rest/health"

curl -sS -X POST "https://${DAS_DOMAIN}/rpc/${DAS_RPC_SECRET_PATH}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"das_healthCheck","params":[]}'
```

Both should succeed. If RPC fails, confirm `make doctor` passes before debugging nginx.

#### 8.7 Production hardening

- Put the public REST hostname behind **CDN/WAF** with rate limiting.
- Keep RPC on the secret path only; rotate the path if it leaks (requires keyset update).
- Prefer **VPN or mTLS** for RPC if your committee policy requires stronger controls than a secret URL.
- Do not open `9876`/`9877` to `0.0.0.0/0` and rely on IP allowlists of Blessnet cluster node egress — those IPs are not stable on default Kubernetes without a NAT gateway.

### 9. DAS peer backfill

If the chain already has batches before you join, or your DAS missed stores, the validator will log `Couldn't fetch DAS batch contents` / `Unable to find data` for inbox hashes. Configure **peer backfill** so your DAS can fetch missing batches from siblings and store them locally.

Details: [docs/das-peer-backfill.md](docs/das-peer-backfill.md).

#### 9.1 Get sibling REST URLs from Blessnet ops

Ask for every **other** committee member's public REST base on your profile, for example:

```text
https://das-alpha.test.bless.net/rest
https://das-beta.test.bless.net/rest
```

Do **not** include your own URL. Use the [handoff template](docs/blessnet-ops-handoff.md#request-to-send-blessnet-ops-sibling-rest-urls).

#### 9.2 Configure `env/das.env`

```bash
# Comma-separated, no spaces — sibling HTTPS bases ending in /rest
DAS_REST_AGGREGATOR_URLS=https://das-alpha.test.bless.net/rest,https://das-beta.test.bless.net/rest
```

`compose.yaml` enables `daserver` REST aggregator with this list. No on-chain change.

#### 9.3 Apply and verify

```bash
make validate
docker compose --env-file env/das.env --env-file env/validator.env up -d arbitrum-das
# or: make down && make up
```

Confirm aggregator URLs are in the running container:

```bash
docker inspect arbitrum-das --format '{{json .Args}}' | tr ',' '\n' | grep -A1 rest-aggregator.urls
```

Watch backfill while the validator catches up:

```bash
docker logs orbit-validator -f 2>&1 | grep -iE 'fetch DAS|reading inbox'
docker logs arbitrum-das -f 2>&1 | grep -iE 'get-by-hash|Unable to find'
```

404 loops on the **same hash** should stop once a sibling has the batch. If a sibling also returns 404, escalate to Blessnet ops (data may not exist on the DAC).

Optional: test one hash manually:

```bash
curl -I "https://<sibling>/rest/get-by-hash/<hash-from-validator-log>"
```

---

## Upgrading existing committee nodes

### Staker strategy (`Defensive`, v0.2.1+)

If you deployed before the default changed from `MakeNodes` to `Defensive`, pull latest and recreate the validator (no on-chain change):

```bash
cd ~/committee-node
git pull
docker compose --env-file env/das.env --env-file env/validator.env up -d --force-recreate validator
```

Confirm the running process:

```bash
docker inspect orbit-validator --format '{{json .Args}}' | tr ',' '\n' | grep -A1 staker.strategy
```

### Peer backfill (DAS 404s)

For servers that already completed steps 1–8 (doctor passes, nginx/TLS live, keyset registered) but the validator is stuck on DAS 404s:

1. **Pull latest repo** on the droplet:

   ```bash
   cd ~/committee-node
   git pull
   ```

2. **Get sibling REST URLs** from Blessnet ops (same as [step 9.1](#91-get-sibling-rest-urls-from-blessnet-ops)).

3. **Edit `env/das.env`** — add or update:

   ```bash
   DAS_REST_AGGREGATOR_URLS=https://das-alpha.test.bless.net/rest,https://das-beta.test.bless.net/rest
   ```

   Remove any stale `AWS_TLS_CRT_SECRET` / `AWS_TLS_KEY_SECRET` lines if present; rely on `COMMITTEE_PROFILE` only (see [tls-aws-secrets-manager.md](docs/tls-aws-secrets-manager.md)).

4. **Validate and recreate DAS** (validator can keep running; recreating both is also fine):

   ```bash
   make validate
   docker compose --env-file env/das.env --env-file env/validator.env up -d --force-recreate arbitrum-das
   ```

5. **Verify** ([step 9.3](#93-apply-and-verify)) — validator should progress past previously stuck inbox batches.

6. **No nginx or keyset changes** required for peer backfill alone. Re-hand URLs only if you changed RPC/REST paths or BLS key.

| Already done | Needed for this upgrade |
|--------------|------------------------|
| Step 8 nginx + TLS | No change |
| Keyset registered | No change |
| `make doctor` local | No change |
| `env/das.network.env` | No change |
| `env/das.env` | Add `DAS_REST_AGGREGATOR_URLS` |
| `compose.yaml` (from git pull) | Picks up new `daserver` aggregator flags |

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
make ps      # service status
make logs    # tail both services (last 200 lines, follow)
```

### Check logs

From the repo root:

```bash
# both services (follow)
make logs

# last N lines without following
docker compose --env-file env/das.env --env-file env/validator.env logs --tail=100

# one service
docker compose --env-file env/das.env --env-file env/validator.env logs arbitrum-das --tail=100 -f
docker compose --env-file env/das.env --env-file env/validator.env logs validator --tail=100 -f
```

If a container is crash-looping and `compose logs` is empty or slow, read the container directly:

```bash
docker logs arbitrum-das --tail=100
docker logs orbit-validator --tail=100
docker logs orbit-validator --tail=100 -f   # follow
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

- External committee validators use staker strategy **`Defensive`**: they follow the chain and only post on the parent chain when they disagree with an assertion. Blessnet's **internal** `validator-nitro` should keep **`MakeNodes`** so one operator posts assertions; external members still participate in fast confirmation without racing for gas.
- Images are pinned by digest in env files. Update digests as part of release process.
- For external validator hosts, `SEQUENCER_FEED_URL` must be externally reachable.
- `PARENT_CHAIN_BEACON_RPC` is required for Ethereum/Sepolia blob reads.
- Keep private keys out of shell history and git.
- Expose DAS over HTTPS via nginx (step 8); do not publish ports `9876`/`9877` to the internet.
- Set `DAS_REST_AGGREGATOR_URLS` to sibling committee REST bases (step 9) so late joiners can backfill batch data.
