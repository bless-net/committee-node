# TLS from AWS Secrets Manager (committee droplet)

## What you are doing

Blessnet keeps a **wildcard TLS certificate** in AWS Secrets Manager. Your droplet downloads that cert, saves it as two local files, and nginx uses those files for HTTPS on `DAS_DOMAIN`.

**You run two make targets:**

```bash
make fetch-tls-aws    # download cert + key from AWS → /etc/ssl/...
make setup-nginx-das  # configure nginx to use those files
```

That is the entire AWS integration on a committee node.

---

## What you do **not** do on the droplet

Rollup README **§14.0** (ingress-nginx, External Secrets Operator, `kubectl apply -f k8s/tls/…`) is **Kubernetes only**. Ignore it on the committee host.

| Rollup (k8s) | Committee droplet |
|--------------|-------------------|
| ESO syncs secrets into the cluster | `make fetch-tls-aws` |
| Ingress uses a `TLS` secret | nginx uses `DAS_TLS_CERT` / `DAS_TLS_KEY` files |

Same secrets in AWS; different sync path.

---

## Before you start

1. **`make doctor` passes** on the droplet.
2. **DNS A record** — a hostname for this server points at the droplet’s **public IP** (not a URL):
   - **Type:** `A`
   - **Name:** e.g. `das-member` → full name `das-member.bless.net` (mainnet) or `das-member.test.bless.net` (testnet)
   - **Value:** this droplet’s public IPv4 (`curl -4 -s ifconfig.me` on the server — same IP you use for SSH)
   - Set `DAS_DOMAIN` in `env/das.network.env` to that full hostname
   - Verify: `dig +short $DAS_DOMAIN A` returns the droplet IP
   - Usually created by whoever manages the `bless.net` DNS zone (ask Blessnet ops if you do not control it)
3. **AWS access** — ask whoever runs Blessnet AWS to give you an **IAM access key** that can read the two TLS secrets for your profile (mainnet or testnet). You need:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

If the wildcard cert is not in Secrets Manager yet, that team does rollup `docs/tls-certificate-strategy.md` (Steps 0–3) first. You only wait for the key — you do not run those steps on the droplet.

---

## Step-by-step (on the committee droplet)

All commands from the **committee-node repo root** unless noted.

### Step 1 — Install tools

```bash
sudo apt-get update
sudo apt-get install -y nginx awscli
```

### Step 2 — Store AWS credentials on the host

Pick **one** method.

**Method A — `aws configure` (simplest for a single operator)**

```bash
aws configure
# AWS Access Key ID:     <paste from Blessnet ops>
# AWS Secret Access Key: <paste from Blessnet ops>
# Default region name: us-east-1
# Default output format: json
```

Test:

```bash
aws sts get-caller-identity
```

**Method B — credentials file (good for automation)**

```bash
sudo install -d -m 700 /etc/committee-node
sudo tee /etc/committee-node/aws-credentials.env >/dev/null <<'EOF'
AWS_ACCESS_KEY_ID=REPLACE_ME
AWS_SECRET_ACCESS_KEY=REPLACE_ME
AWS_REGION=us-east-1
EOF
sudo chmod 600 /etc/committee-node/aws-credentials.env
# sudo nano /etc/committee-node/aws-credentials.env   # paste real values
```

`fetch-tls-from-aws.sh` loads `/etc/committee-node/aws-credentials.env` automatically when present.

Test:

```bash
set -a && source /etc/committee-node/aws-credentials.env && set +a
aws sts get-caller-identity
```

### Step 3 — Create `env/das.network.env`

```bash
cp env/das.network.env.example env/das.network.env
chmod 600 env/das.network.env
make gen-das-rpc-secret-path
```

Edit `env/das.network.env`. **Minimum required edits:**

```bash
nano env/das.network.env
```

| Variable | What to set |
|----------|-------------|
| `COMMITTEE_PROFILE` | `mainnet` or `testnet` |
| `DAS_DOMAIN` | Your hostname, e.g. `das-member.bless.net` |
| `DAS_RPC_SECRET_PATH` | Already set by `make gen-das-rpc-secret-path` |

Leave these as-is unless you have a reason to change them:

```bash
DAS_TLS_CERT=/etc/ssl/certs/das-fullchain.pem
DAS_TLS_KEY=/etc/ssl/private/das-privkey.pem
AWS_REGION=us-east-1
```

With `COMMITTEE_PROFILE=mainnet`, the script reads:

- `blessnet/mainnet/tls/wildcard-crt`
- `blessnet/mainnet/tls/wildcard-key`

With `COMMITTEE_PROFILE=testnet`, it reads the `testnet` paths instead. You do not need to type the secret names unless you override them.

Optional: if you used `aws configure --profile blessnet-committee`, add:

```bash
AWS_PROFILE=blessnet-committee
```

### Step 4 — Download the cert from AWS

```bash
make fetch-tls-aws
```

**Expected output:** paths to `/etc/ssl/certs/das-fullchain.pem` and `/etc/ssl/private/das-privkey.pem`, plus certificate subject and expiry dates.

**If this fails:**

| Error | Fix |
|-------|-----|
| `Unable to locate credentials` | Complete Step 2 |
| `AccessDeniedException` | Ask Blessnet ops to fix IAM permissions on the two secrets |
| `ResourceNotFoundException` | Wrong `COMMITTEE_PROFILE` or secrets not created yet in AWS |
| `aws CLI not found` | `sudo apt-get install -y awscli` |

Manual check (optional):

```bash
set -a && source env/das.network.env && set +a
aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$AWS_TLS_CRT_SECRET" \
  --query SecretString --output text | head -1
# should print: -----BEGIN CERTIFICATE-----
```

### Step 5 — Configure nginx

```bash
make setup-nginx-das
```

**Expected output:** `nginx -t` succeeds, nginx reloads, prints your REST and RPC URLs.

### Step 6 — Verify HTTPS

```bash
set -a && source env/das.network.env && set +a

curl -I "https://${DAS_DOMAIN}/rest/health"

curl -sS -X POST "https://${DAS_DOMAIN}/rpc/${DAS_RPC_SECRET_PATH}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"das_healthCheck","params":[]}'
```

Both should succeed. Continue with [README step 8.5](../README.md#85-urls-to-hand-blessnet) to hand URLs to Blessnet.

### Step 7 — After cert rotation in AWS

Blessnet ops rotates the wildcard in Secrets Manager from time to time. When they tell you (or on a schedule):

```bash
make fetch-tls-aws
sudo nginx -t && sudo systemctl reload nginx
```

---

## Quick reference — secret names

| Profile | Hostname example | Cert secret | Key secret |
|---------|------------------|-------------|------------|
| mainnet | `das-member.bless.net` | `blessnet/mainnet/tls/wildcard-crt` | `blessnet/mainnet/tls/wildcard-key` |
| testnet | `das-member.test.bless.net` | `blessnet/testnet/tls/wildcard-crt` | `blessnet/testnet/tls/wildcard-key` |

Region: **`us-east-1`** (change `AWS_REGION` only if Blessnet ops says the secrets live elsewhere).

---

## Request to send Blessnet ops (AWS access)

```
We are setting up a committee node and need to pull the wildcard TLS cert from AWS Secrets Manager (same secrets as rollup RPC ingress).

Please provide:
1) IAM access key (Access Key ID + Secret Access Key) with secretsmanager:GetSecretValue on:
   - blessnet/<mainnet|testnet>/tls/wildcard-crt
   - blessnet/<mainnet|testnet>/tls/wildcard-key
   Region: us-east-1

2) Confirm the wildcard is already in Secrets Manager (or tell us when it will be).

We will run `make fetch-tls-aws` on the droplet — we do not need ESO or kubectl access.
```

---

## Background (optional reading)

- Rollup cert strategy and rotation: rollup repo `docs/tls-certificate-strategy.md`
- Rollup k8s TLS sync: rollup README §14.0 (not run on committee droplet)
- Manual cert / Let's Encrypt instead of AWS: [README step 8.4](../README.md#84-nginx-and-tls) options B and C
