# Blessnet ops handoff (committee DAS networking)

Use this when onboarding a committee node. It explains what the **committee operator** configures on their droplet and what **Blessnet ops** must provide or do on the sequencer / DAC side.

For droplet setup steps, see [README step 8](../README.md#8-expose-das-endpoints-committee-networking).

---

## Traffic directions (read this first)

Committee networking is confusing because traffic flows in **both directions**:

| Traffic | Direction | Config on committee host | Typical Blessnet component |
|---------|-----------|--------------------------|----------------------------|
| **Sequencer feed** | Committee validator → Blessnet | `SEQUENCER_FEED_URL` in `env/validator.env` | Sequencer feed (`:9642`) |
| **L2 RPC forwarding** | Committee validator → Blessnet | `SEQUENCER_FORWARDING_TARGET` in `env/validator.env` | Sequencer HTTP RPC |
| **DAS RPC (`das_store`)** | Blessnet → committee DAS | HTTPS secret path via nginx (README step 8) | Batch poster |
| **DAS REST (`get-by-hash`)** | Blessnet + other nodes → committee DAS | HTTPS `/rest/` via nginx | Nitro nodes, mirrors, aggregators |

**`SEQUENCER_FEED_URL` is not the DAS RPC source IP.** The feed URL is where the committee validator **connects to**. DAS RPC is the opposite: Blessnet **connects to** the committee host over the registered HTTPS URLs.

**Default committee-node setup (README step 8) does not use IP allowlisting.** Blessnet cluster egress IPs change when Kubernetes pods move unless you operate a stable NAT gateway. Committee members expose DAS on **443** with TLS, a **secret RPC path**, and a public **REST** prefix instead.

---

## What the committee operator provides to Blessnet ops

After [README step 8](../README.md#8-expose-das-endpoints-committee-networking):

| Item | Example | Notes |
|------|---------|-------|
| **DAS BLS public key** | contents of `bls_keys/das_bls.pub` | Base64-encoded; unique per committee member |
| **DAS RPC URL** | `https://das-member.example.com/rpc/<secret-suffix>` | JSON-RPC; `das_store` from batch poster; share out-of-band |
| **DAS REST URL** | `https://das-member.example.com/rest` | Nitro rest-aggregator base; health at `/rest/health` |
| **Committee operator contact** | — | For keyset updates and URL rotation |

Optional but helpful:

- Droplet hostname / provider / region
- Confirmation that `make doctor` passes locally
- Date RPC secret path was generated (do not rotate without keyset update)

---

## What we need from Blessnet ops

### 1. DAC keyset registration (required)

Blessnet ops registers on-chain (`SequencerInbox` keyset update):

- Committee member **BLS public key**
- **DAS RPC URL** (exact HTTPS string committee provides, including secret path)
- **DAS REST URL** (exact HTTPS string — typically `https://<domain>/rest`)

Also add the REST URL to **`DAS_REST_AGGREGATOR_URLS`** in the rollup `.env` and re-run `k8s:prepare-values` before applying Nitro config.

Until this is live, the batch poster will not store to this DAS and nodes will not fetch from this REST URL.

### 2. Coordinated connectivity test (required before production)

Before relying on the committee member in production:

1. Committee completes step 8 and sends RPC + REST URLs.
2. Blessnet ops configures keyset (or staging keyset).
3. Blessnet ops runs from **production batch-poster egress** (not an engineer's laptop):

   ```bash
   curl -sS -X POST "https://<committee-domain>/rpc/<secret>" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":0,"method":"das_healthCheck","params":[]}'
   ```

4. Blessnet ops confirms REST health:

   ```bash
   curl -I "https://<committee-domain>/rest/health"
   ```

5. Committee confirms direct ports stay closed externally:

   ```bash
   nc -vz <committee-domain> 9876   # should fail
   nc -vz <committee-domain> 9877   # should fail
   ```

**A test from an engineer's laptop is not sufficient for production sign-off** if your policy requires proving batch-poster path specifically — but with HTTPS + secret RPC path, laptop and cluster use the same URL (unlike IP-allowlist mode).

### 3. Validator-facing endpoints (usually already configured)

Committee operator needs these **from** Blessnet (not the other way around):

| Variable | Purpose |
|----------|---------|
| `SEQUENCER_FEED_URL` | Validator subscribes to sequencer feed |
| `SEQUENCER_FORWARDING_TARGET` | L2 RPC forwarding |
| `PARENT_CHAIN_RPC` / `PARENT_CHAIN_BEACON_RPC` | L1 + blobs |
| `SEQUENCER_INBOX_ADDRESS` | DAS parent-chain reads |
| `ROLLUP_ADDRESS` | Fast-confirm checks |

These are independent of DAS exposure.

### 4. Sibling REST URLs for peer backfill (required)

Each committee operator needs the **public REST base URLs of every other committee member** (not their own) for `DAS_REST_AGGREGATOR_URLS` in `env/das.env` ([README step 9](../README.md#9-das-peer-backfill)).

Provide a comma-separated list, e.g.:

```text
https://das-alpha.test.bless.net/rest,https://das-beta.test.bless.net/rest
```

Update this list when members join or leave. Committee operators update `env/das.env` and recreate `arbitrum-das` — **no on-chain change**.

#### Request to send Blessnet ops (sibling REST URLs)

```
Please send the public REST base URLs (https://<host>/rest) of all other <testnet|mainnet> committee members, for our DAS peer backfill config (DAS_REST_AGGREGATOR_URLS). Exclude our own URL: https://<our-DAS_DOMAIN>/rest
```

### 5. Change management (required for production)

Blessnet ops should notify committee operators **before**:

- Rotating DAS URLs or BLS keys
- Keyset updates that add/remove committee members

Committee operators must update nginx secrets and re-hand URLs when the RPC path rotates. Until keyset and nginx config match, **`das_store` fails** for that member.

---

## Optional: IP allowlisting instead of secret-path HTTPS

Some committees may still choose **direct `http://IP:9876` + firewall allowlist**. That requires Blessnet to provide **stable batch-poster egress IP(s)** and notify committee operators before they change. Default Kubernetes egress without NAT is **not stable** — see historical note in git history for `SEQUENCER_IP` / Caddy-based docs.

Preferred alternatives if IP allowlisting is insufficient:

| Option | Who sets it up |
|--------|----------------|
| **HTTPS + secret RPC path** (README step 8 default) | Committee operator |
| **Site-to-site VPN** or **WireGuard / Tailscale** | Blessnet ops + committee operator |
| **Stable NAT / egress gateway** on the cluster | Blessnet ops |
| **mTLS on RPC** | Both sides |

Do not leave `9876` open to `0.0.0.0/0` in production.

---

## Copy-paste: handoff after step 8

Fill in and send after nginx + TLS are running (README step 8):

```
Subject: Committee member DAS endpoints — keyset registration

BLS public key (das_bls.pub):
<paste base64 contents>

DAS RPC URL (private — batch poster only):
https://<DAS_DOMAIN>/rpc/<DAS_RPC_SECRET_PATH>

DAS REST URL (public):
https://<DAS_DOMAIN>/rest

Please:
1) Register the above in the DAC keyset
2) Add the REST URL to DAS_REST_AGGREGATOR_URLS and refresh Nitro config
3) Run das_healthCheck from production batch-poster to our RPC URL
4) Confirm GET/HEAD /rest/health returns 200

Committee operator contact: <name / signal>
```

---

## Troubleshooting checklist

| Symptom | Likely cause |
|---------|----------------|
| `make doctor` OK, RPC fails from Blessnet | Wrong RPC URL in keyset; nginx secret path mismatch; cert/TLS error |
| REST 404 on `/rest/health` | nginx not running; wrong domain; cert issue |
| REST 200 locally on `:9877`, fails on HTTPS | nginx misconfigured; UFW/cloud firewall blocks 443 |
| Batches not stored after keyset update | Wrong RPC URL in keyset; BLS key mismatch; RPC secret path rotated without keyset update |
| RPC works from laptop, not from Blessnet | Wrong URL registered; Blessnet still using old keyset; TLS trust issue on cluster |
| Validator `Couldn't fetch DAS batch contents` loop | Missing/wrong `DAS_REST_AGGREGATOR_URLS`; sibling also missing hash — see [das-peer-backfill.md](das-peer-backfill.md) |

---

## Related docs

- [README step 8](../README.md#8-expose-das-endpoints-committee-networking) — droplet networking
- [README step 9](../README.md#9-das-peer-backfill) — DAS peer backfill
- [README upgrade path](../README.md#upgrading-existing-committee-nodes-peer-backfill) — existing servers
- [das-peer-backfill.md](das-peer-backfill.md) — aggregator details
- [Arbitrum: deploy a DAS](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/data-availability/data-availability-committees/deploy-das)
- [Arbitrum: configure the DAC](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/data-availability/data-availability-committees/configure-dac)
