# TLS from AWS Secrets Manager (committee droplet)

Supplement to **[README step 8](../README.md#8-expose-das-endpoints-committee-networking)** — AWS credentials and `make fetch-tls-aws` only. DNS, `env/das.network.env`, firewall, nginx install, URL handoff, and HTTPS checks are all in the README.

## What you are doing

Blessnet stores a wildcard TLS cert in AWS Secrets Manager. On the droplet:

```bash
make fetch-tls-aws    # download cert + key → DAS_TLS_CERT / DAS_TLS_KEY
make setup-nginx-das  # README step 8.4 — nginx uses those files
```

`COMMITTEE_PROFILE` in `env/das.network.env` (set in [README §8.2](../README.md#82-record-exposure-settings)) picks which secrets to read — do **not** set `AWS_TLS_CRT_SECRET` / `AWS_TLS_KEY_SECRET` in the env file.

| Profile | Secrets Manager paths |
|---------|----------------------|
| `mainnet` | `blessnet/mainnet/tls/wildcard-crt` + `wildcard-key` |
| `testnet` | `blessnet/testnet/tls/wildcard-crt` + `wildcard-key` |

Region: **`us-east-1`** (`AWS_REGION` in `env/das.network.env`).

---

## What you do **not** do on the droplet

Rollup README **§14.0** (ingress-nginx, External Secrets Operator, `kubectl apply -f k8s/tls/…`) is **Kubernetes only**.

| Rollup (k8s) | Committee droplet |
|--------------|-------------------|
| ESO syncs secrets into the cluster | `make fetch-tls-aws` |
| Ingress uses a `TLS` secret | nginx uses `DAS_TLS_CERT` / `DAS_TLS_KEY` files |

---

## Before you start

1. Complete README **§8.1–8.3** (DNS A record, `env/das.network.env`, firewall). Peer backfill is **§9** (`DAS_REST_AGGREGATOR_URLS` in `env/das.env`).
2. Get an **IAM access key** from Blessnet ops with `secretsmanager:GetSecretValue` on the two TLS secrets for your profile (see [request template](#request-to-send-blessnet-ops-aws-access) below).

If the wildcard is not in Secrets Manager yet, Blessnet does rollup `docs/tls-certificate-strategy.md` (Steps 0–3) first.

---

## 1 — Install AWS CLI

Ubuntu 24.04 has no `awscli` apt package:

```bash
make install-aws-cli
aws --version   # expect aws-cli/2.x
```

(Install `nginx` in [README §8.4](../README.md#84-nginx-and-tls) if not already installed.)

---

## 2 — Store AWS credentials on the host

**Method A — `aws configure`**

```bash
aws configure
# Access Key ID, Secret Access Key, region us-east-1

aws sts get-caller-identity
```

**Method B — file** (loaded automatically by `fetch-tls-from-aws.sh`)

```bash
sudo install -d -m 700 /etc/committee-node
sudo nano /etc/committee-node/aws-credentials.env   # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
sudo chmod 600 /etc/committee-node/aws-credentials.env
```

If you used `aws configure --profile blessnet-committee`, add `AWS_PROFILE=blessnet-committee` to `env/das.network.env`.

---

## 3 — Download the cert

```bash
make fetch-tls-aws
```

Expected: writes `/etc/ssl/certs/das-fullchain.pem` and `/etc/ssl/private/das-privkey.pem`, prints cert dates.

| Error | Fix |
|-------|-----|
| `Unable to locate credentials` | §2 above |
| `AccessDeniedException` | Wrong profile vs IAM user (e.g. testnet user + mainnet secrets), or ask ops for policy fix |
| `ResourceNotFoundException` | Secrets not created yet, or wrong `COMMITTEE_PROFILE` |
| Fetches `mainnet` paths on a testnet host | Remove any `AWS_TLS_CRT_SECRET` / `AWS_TLS_KEY_SECRET` lines from `env/das.network.env`; rely on `COMMITTEE_PROFILE` only |

---

## 4 — Continue in the README

```bash
make setup-nginx-das          # §8.4
# verify + hand URLs          # §8.5–8.6
```

---

## After cert rotation

```bash
make fetch-tls-aws
sudo nginx -t && sudo systemctl reload nginx
```

---

## Request to send Blessnet ops (AWS access)

```
We are setting up a committee node and need to pull the wildcard TLS cert from AWS Secrets Manager (same secrets as rollup RPC ingress).

Please provide:
1) IAM access key with secretsmanager:GetSecretValue on:
   - blessnet/<mainnet|testnet>/tls/wildcard-crt
   - blessnet/<mainnet|testnet>/tls/wildcard-key
   Region: us-east-1

2) Confirm the wildcard is already in Secrets Manager (or tell us when it will be).

We run `make fetch-tls-aws` on the droplet — we do not need ESO or kubectl access.
```

---

## Background

- Rollup cert strategy / rotation: rollup `docs/tls-certificate-strategy.md`
- Manual cert or Let's Encrypt: [README §8.4](../README.md#84-nginx-and-tls) options B and C
