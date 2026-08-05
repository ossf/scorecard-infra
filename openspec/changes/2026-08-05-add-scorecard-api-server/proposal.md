# Proposal: Scorecard API Server (cloud-agnostic, hybrid cache + live)

## Why

The public OpenSSF Scorecard API (`api.scorecard.dev`) is invaluable but has two
limits for anyone outside the public ecosystem: it only covers repositories that
opted in via `publish_results: true`, and its production stack is wedded to Google
Cloud (GCS, BigQuery, PubSub, Cloud Endpoints). Teams that want Scorecard results
for **private** repositories, for repos not in the weekly public scan, or hosted on
**non-GCP** infrastructure have no first-class option.

At the same time, the read path is already `gocloud.dev/blob`-based
(`scorecard-webapp`'s `get_results.go`), and the scan engine (`pkg/scorecard.Run`)
imports out-of-tree — so a portable, self-hostable server is mostly integration
work, not new invention. This change introduces that server: it speaks the existing
`scorecard-webapp` GET contract (so `scorecard-mcp` queries it unchanged via
`--base-url`), serves cached results from **any** object store, and **generates
results live on demand** when the cache misses.

## What Changes

- Introduce a new Go HTTP server exposing the **`scorecard-webapp` GET contract**:
  `GET /projects/{host}/{org}/{repo}` (optional `?commit=`) and `/badge`, returning
  canonical Scorecard **JSON2**. It is a drop-in `--base-url` target for
  `scorecard-mcp`.
- Add a **`GET /capabilities`** endpoint so the server advertises its own caveats,
  freshness policy, and check coverage. (`scorecard-mcp` today hardcodes the public
  cache's caveats, which are wrong for any other backend — see design D7.)
- Source results through a **read-through cache** (the orchestrator): serve a stored
  result when fresh; on miss/stale, **trigger a live scan**, persist it, and return
  it. Freshness is policy-driven — commit-pinned results are immutable; `latest`
  results use a TTL.
- Persist results through a **cloud-agnostic blob store** (`gocloud.dev/blob`), with
  S3/Azure/GCS/local-file/in-memory backends selected by a **URL env var**. The
  object-key layout matches `scorecard-webapp` exactly:
  `{host}/{org}/{repo}[/{commit}]/results.json`. **No BigQuery; no hardcoded bucket.**
- Generate results with a **live scan engine** wrapping `pkg/scorecard.Run` (reused
  SCM/aux clients, JSON2 formatter), fronted by a **token & rate manager** (SCM API
  rate limits are the real bottleneck).
- Apply **responsible-AI framing**: results are signals, not verdicts; every response
  declares its `source` (cached vs. live), freshness, and completeness.

## Capabilities

### New Capabilities

- `api-server`: HTTP runtime implementing the `scorecard-webapp` GET contract
  (`/projects/{host}/{org}/{repo}` + `?commit=`, `/badge`), a `/capabilities`
  endpoint that advertises this server's caveats/coverage/freshness, `/health` +
  `/readyz`, JSON2 responses, `platform/owner/repo` routing, consistent error
  handling, and responsible-AI framing on every response. Verified as a drop-in
  `--base-url` target for `scorecard-mcp`.
- `result-store`: cloud-agnostic persistence of Scorecard results via
  `gocloud.dev/blob`, backend chosen by a URL env var (S3-compatible,
  Azure Blob, GCS, local file, in-memory), using the `{host}/{org}/{repo}[/{commit}]/results.json`
  key contract and storing canonical JSON2 bodies.
- `result-cache`: a read-through cache/orchestrator that serves fresh stored results,
  triggers a live scan on miss/stale, applies a freshness policy (commit = immutable,
  `latest` = TTL), coalesces concurrent requests for the same key via single-flight,
  and decides synchronous-with-timeout vs. asynchronous responses. Guarantees
  provenance (source, resolved commit SHA, date, Scorecard version) on every result.
- `live-scan`: on-demand result generation via `pkg/scorecard.Run` with clients
  created once and reused, a JSON2 formatter that writes results back to the store,
  and a token & rate manager (SCM token pool, per-host rate limiting, backoff/retry).
  Declares its coverage (all checks; any repo the token can access, including private).

### Modified Capabilities

<!-- None — this is a greenfield change; no existing specs are modified. -->

## Impact

- **New code:** a new Go module (this repo). Packages: `cmd/scorecard-api`,
  `internal/store` (blob), `internal/orchestrator` (cache), `internal/scan`
  (engine), `internal/tokens` (rate/token). Contract handlers reuse the
  `scorecard-webapp` OpenAPI/models where importable.
- **Dependencies:** `github.com/ossf/scorecard/v5` (`pkg/scorecard`, `docs/checks`);
  `gocloud.dev/blob` (+ `s3blob`, `azureblob`, `gcsblob`, `fileblob`, `memblob`
  drivers); the `scorecard-webapp` generated models (or a vendored `openapi.yaml`).
- **External systems:** SCM providers (GitHub/GitLab/Azure DevOps) and Scorecard's
  auxiliary data sources (OSS-Fuzz, OpenSSF Best Practices, OSV/deps.dev) during live
  scans; an object store for persistence. All selected by configuration.
- **Consumers:** `scorecard-mcp` via `--base-url` (primary/acceptance test); any
  HTTP client speaking the webapp contract; badges.
- **Compatibility:** greenfield — no breaking changes. Wire-compatible with the
  public API's GET contract by construction.

## Non-goals

- **Message broker / distributed workers.** v0 uses an in-process worker pool;
  `gocloud.dev/pubsub` fan-out (SQS/Service Bus/Kafka/NATS) is a later change.
- **Warm-cache scheduler.** Proactive interval scanning of a configured org/repo
  list (to keep the cache warm) is deferred.
- **Analytics / index layer.** Cross-repo listing and trend queries
  (DuckDB/Parquet, Postgres, ClickHouse — what BigQuery does upstream) are out of
  scope; the core path is per-repo GET.
- **Signed-result upload (`POST /projects/...`).** The Sigstore/Fulcio/Rekor
  community-submission path is out of scope; this server computes its own results.
- **API authn/authz and multi-tenancy.** No request-level auth in v0; noted as a
  prerequisite before exposing private-repo results beyond a trusted boundary.
- **Reimplementing scoring or checks.** We consume `pkg/scorecard`; we do not
  reinvent check logic or the aggregate score.
- **Internal deployment glue.** Object-store endpoints, org/repo scan lists,
  orchestration manifests, and token sourcing for any specific internal deployment
  live in a separate internal repo, not here.
