# TLS from AWS Secrets Manager (committee droplet)

Blessnet stores wildcard TLS certificates in **AWS Secrets Manager**. On the **rollup** cluster, External Secrets Operator (ESO) syncs them into Kubernetes `TLS` secrets for ingress. A **committee node** is a bare-metal / droplet host with **nginx** — there is no ingress controller or ESO here. You pull the same secrets with the **AWS CLI** and point nginx at local PEM files.

**AWS-side prerequisite (one-time, shared with rollup):** wildcard cert and key in Secrets Manager, plus an IAM principal that can read them. If that is not done yet, use the rollup repo `docs/tls-certificate-strategy.md` (**Steps 0–3 only**). Rotation and incident recovery are also documented there.

**Cluster-side prerequisite (rollup only, not committee):** ingress-nginx, ESO, `k8s/tls/*` manifests — see rollup README §14.0. Committee operators **do not** run those steps on the droplet.

---

## Secret names and wildcard scope

Same secrets as rollup RPC ingress:

| Profile | Wildcard covers | `AWS_TLS_CRT_SECRET` | `AWS_TLS_KEY_SECRET` |
|---------|-----------------|----------------------|----------------------|
| **mainnet** | `*.bless.net` | `blessnet/mainnet/tls/wildcard-crt` | `blessnet/mainnet/tls/wildcard-key` |
| **testnet** | `*.test.bless.net` | `blessnet/testnet/tls/wildcard-crt` | `blessnet/testnet/tls/wildcard-key` |

Secrets Manager holds **plaintext PEM bodies** (`tls.crt` / `tls.key` content), not JSON wrappers.

Pick a `DAS_DOMAIN` under the wildcard (e.g. `das-member.bless.net` or `das-member.test.bless.net`) and create a DNS **A** record to the committee droplet.

---

## IAM on the committee droplet

Create a **dedicated IAM access key** for the committee host (do not reuse the ESO operator key from k8s unless policy is intentionally shared). Minimum policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:blessnet/mainnet/tls/wildcard-crt-*",
        "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:blessnet/mainnet/tls/wildcard-key-*"
      ]
    }
  ]
}
```

Adjust `ACCOUNT_ID`, region, and secret ARNs for testnet.

On the droplet, configure credentials **once** (pick one):

```bash
# Option A — profile in ~/.aws/credentials
aws configure --profile blessnet-committee

# Option B — env vars in a root-only file (example)
sudo install -d -m 700 /etc/committee-node
sudo tee /etc/committee-node/aws-credentials.env >/dev/null <<'EOF'
AWS_ACCESS_KEY_ID=REPLACE_ME
AWS_SECRET_ACCESS_KEY=REPLACE_ME
AWS_REGION=us-east-1
EOF
sudo chmod 600 /etc/committee-node/aws-credentials.env
```

---

## Configure `env/das.network.env`

```bash
cp env/das.network.env.example env/das.network.env
chmod 600 env/das.network.env
```

Set profile-driven secret names (or set `AWS_TLS_*` explicitly):

```bash
# mainnet or testnet
COMMITTEE_PROFILE=mainnet

DAS_DOMAIN=das-member.bless.net
DAS_RPC_SECRET_PATH="$(openssl rand -hex 16)"

DAS_TLS_CERT=/etc/ssl/certs/das-fullchain.pem
DAS_TLS_KEY=/etc/ssl/private/das-privkey.pem

AWS_REGION=us-east-1
```

`env/das.network.env.example` documents the mainnet/testnet secret name defaults when `COMMITTEE_PROFILE` is set.

---

## Fetch cert and install nginx

Install AWS CLI v2 on the droplet if needed:

```bash
sudo apt-get update
sudo apt-get install -y awscli
```

From repo root:

```bash
# loads env/das.network.env; writes DAS_TLS_CERT and DAS_TLS_KEY
make fetch-tls-aws

# install nginx site (validates PEM paths, reloads nginx)
make setup-nginx-das
```

Or run the script directly:

```bash
./scripts/fetch-tls-from-aws.sh
./scripts/setup-nginx-das.sh
```

Verify files:

```bash
sudo openssl x509 -in /etc/ssl/certs/das-fullchain.pem -noout -subject -dates
sudo openssl rsa  -in /etc/ssl/private/das-privkey.pem -check -noout
```

---

## Rotation

When ops rotate the wildcard in Secrets Manager (rollup `docs/tls-certificate-strategy.md`):

```bash
make fetch-tls-aws
sudo nginx -t && sudo systemctl reload nginx
```

Optional: cron on the droplet (e.g. weekly) to refetch and reload if your rotation process does not notify committee hosts.

```bash
# /etc/cron.weekly/committee-fetch-tls
0 3 * * 0 root cd /home/OP_USER/committee-node && ./scripts/fetch-tls-from-aws.sh && systemctl reload nginx
```

---

## Comparison with rollup §14.0

| Rollup (Kubernetes) | Committee node (droplet) |
|---------------------|--------------------------|
| ingress-nginx Helm chart | **nginx** on host (README step 8) |
| ESO + `ClusterSecretStore` | **AWS CLI** (`fetch-tls-from-aws.sh`) |
| `kubectl get secret … TLS_SECRET_NAME` | PEM files at `DAS_TLS_CERT` / `DAS_TLS_KEY` |
| Ingress references `tls.secretName` | `nginx/arbitrum-das.conf.example` `ssl_certificate` paths |

Same Secrets Manager entries; different sync mechanism.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `AccessDeniedException` | IAM policy, wrong region, wrong secret name |
| nginx TLS error after fetch | Secret body must be raw PEM; re-run `openssl x509` / `openssl rsa` checks |
| Browser cert mismatch | `DAS_DOMAIN` not covered by wildcard (e.g. mainnet cert on testnet hostname) |
| `make setup-nginx-das` fails “TLS files not found” | Run `make fetch-tls-aws` first |
