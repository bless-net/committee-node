# DAS peer backfill (REST aggregator)

Supplement to **[README step 9](../README.md#9-das-peer-backfill)**.

## What this does

Your `arbitrum-das` container stores batches from the batch poster (`das_store` on your RPC URL). If you **joined the DAC after** some batches were already posted, or you **missed stores**, local `data/` will not have those hashes.

`DAS_REST_AGGREGATOR_URLS` tells **your** `daserver` to fetch missing batches from **other committee members'** public REST endpoints and save them to local storage (lazy backfill on `get-by-hash` miss).

This is **off-chain config only** — no keyset change.

There is **no central aggregator server**. Each DAS is a peer; your DAS is a **client** that asks siblings when it does not have a hash.

## What you configure

In `env/das.env`:

```bash
DAS_REST_AGGREGATOR_URLS=https://das-alpha.test.bless.net/rest,https://das-beta.test.bless.net/rest
```

| Rule | Detail |
|------|--------|
| **Siblings only** | Do not include your own public REST URL |
| **Format** | Comma-separated, **no spaces**, each URL is the nginx REST **base** ending in `/rest` |
| **Not internal Docker URL** | Use `https://peer-domain/rest`, not `http://arbitrum-das:9877` |

`compose.yaml` passes this to:

```text
--data-availability.rest-aggregator.enable
--data-availability.rest-aggregator.urls
```

With `local-file-storage` already enabled, fetched batches are written under `data/`.

The co-hosted **validator** keeps using only `http://arbitrum-das:9877` internally. When it requests a missing hash, local DAS fetches from siblings and returns (and stores) the data.

## What to get from Blessnet ops

Ask for the **public REST base URLs of all other committee members** on your profile (testnet/mainnet), e.g.:

```text
https://das-alpha.test.bless.net/rest
https://das-beta.test.bless.net/rest
```

Optional: a published **online URL list** (JSON of active REST endpoints) if Blessnet maintains one — can be added later as a separate `daserver` flag if needed.

## Verify backfill

After `make up`, when the validator is catching up, watch DAS logs:

```bash
docker logs arbitrum-das -f 2>&1 | grep -iE 'get-by-hash|aggregator|store'
```

Test a hash that was 404 before (from validator logs) against a sibling:

```bash
curl -I "https://<sibling>/rest/get-by-hash/<hash>"
```

Then confirm local DAS can serve it after fetch (validator log should stop repeating the same 404).

## Optional: eager historical sync

Default in this repo is **lazy** backfill (on demand). To pull **all** historical batches up front, Blessnet ops can provide the parent-chain **deployment block** and you add to `arbitrum-das` in `compose.yaml`:

```yaml
      - --data-availability.rest-aggregator.sync-to-storage.eager
      - --data-availability.rest-aggregator.sync-to-storage.eager-lower-bound-block
      - <deployed-at block number>
      - --data-availability.rest-aggregator.sync-to-storage.state-dir
      - /home/user/data/das-data/syncState
```

Coordinate with Blessnet before enabling eager sync on production.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Validator 404 loop on same hash | Wrong/missing `DAS_REST_AGGREGATOR_URLS`; sibling also missing hash |
| `AccessDenied` / TLS errors fetching peers | Wrong sibling URL; cert/DNS issue on peer |
| Backfill works but new batches still missing | Batch poster not reaching your RPC URL — keyset / nginx secret path |
| Included your own URL in the list | Remove — list siblings only |
