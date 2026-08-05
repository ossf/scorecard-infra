# Bootstrap: scorecard-api

Onboarding for a fresh agent (or human) session working in this repo. It captures
the context that produced the OpenSpec change already on disk, so you can pick up
without re-deriving it.

## Start here

1. Read the OpenSpec change: `openspec list`, then
   `openspec show 2026-08-05-add-scorecard-api-server` (or read
   `openspec/changes/2026-08-05-add-scorecard-api-server/{proposal,design,tasks}.md`).
2. Read `openspec/config.yaml` — it holds the durable project context and per-artifact
   rules.
3. Do the pre-work tasks (group 0) **before** writing the HTTP layer (see below).
4. Then implement against `tasks.md` (46 tasks, groups 0–11), keeping specs and code
   in sync. Do not restructure without updating the spec.

## What this is

A cloud-agnostic, self-hosted (non-OpenSSF) OpenSSF Scorecard results API server.
It is a **read-through cache over an in-process scan engine** ("hybrid"): it serves
pre-computed results and generates them live on demand. It is a drop-in `--base-url`
target for [`uwu-tools/scorecard-mcp`](https://github.com/uwu-tools/scorecard-mcp).

## Contract (match ossf/scorecard-webapp exactly)

- `GET /projects/{host}/{org}/{repo}[?commit=SHA]` -> `ScorecardResult` (JSON2)
- `GET /projects/{host}/{org}/{repo}/badge` -> SVG
- `GET /capabilities` -> this server's mode/coverage/freshness/caveats (NEW)
- `GET /health`, `GET /readyz`

Blob object keys (must match the webapp exactly):

```
{host}/{org}/{repo}/results.json            # latest
{host}/{org}/{repo}/{commit}/results.json   # pinned, immutable
```

Body is canonical Scorecard **JSON2**.

## Chosen layout

```
cmd/scorecard-api/
internal/
  model/         JSON2 + provenance types
  store/         gocloud.dev/blob; s3/azure/gcs/file/mem by URL env; key contract   [port from scorecard-webapp]
  orchestrator/  read-through cache: freshness/TTL, single-flight, sync/async        [NEW — the brain]
  scan/          wraps pkg/scorecard.Run; reused clients; JSON2; writes back to store [ossf/scorecard engine + oss-pulse pattern]
  tokens/        SCM token pool + per-host rate limiter/backoff/retry                 [NEW — critical]
```

## Cloud-agnostic rules (non-negotiable)

- No hardcoded `gs://` anything. All config via env: bucket URL, `latest` TTL,
  request/scan timeouts, enabled checks, worker concurrency, listen port, SCM creds.
- Blank-import all blob drivers: `s3blob`, `azureblob`, `gcsblob`, `fileblob`,
  `memblob`. Creds resolve via each backend's default chain.
- **No BigQuery.** Local dev = `fileblob`; local S3 = a self-hosted
  S3-compatible store; tests = `memblob`.

## Pre-work to resolve before the HTTP layer (tasks 0.x)

- **0.1 — Verify PR #4665's true merge status** in `ossf/scorecard` and decide whether
  to reuse/extend `scorecard serve`'s handler wiring or implement fresh and back-port.
  `scorecard serve` is the closest existing surface (on-demand, `net/http`,
  `GET /?repo=…`, no store, no cloud deps) but does **not** speak the `/projects`
  contract. `main` still uses `net/http`, so treat #4665's chi/REST refactor as
  unlanded until confirmed. See design **D11**.
- **0.2 —** Decide: import `scorecard-webapp` generated models directly vs. vendor
  `openapi.yaml` and regenerate.
- **0.3 —** Confirm the blob key + JSON2 body contract against a real
  `scorecard-webapp` object (design **D4**).

## Why `/capabilities` exists

`scorecard-mcp` currently hardcodes the public cache's caveats
(`internal/provider/rest.go`: opted-in-only; weekly scan omits three checks). Those
are **wrong** for this server (it scans on demand, all checks, any accessible repo).
The server advertises its own caveats/coverage/freshness at `/capabilities` so clients
report provenance correctly. Follow-up (in the scorecard-mcp repo, not here): teach the
MCP to read `/capabilities` instead of hardcoding.

## Upstream graft map (this is an incubator, not a permanent fork)

- Contract handlers + blob read path -> `ossf/scorecard-webapp`
  (bucket-URL parameterization + driver imports).
- Live scan + HTTP surface -> `ossf/scorecard` `scorecard serve`
  (endgame: teach it the `/projects` contract + an optional blob cache).

Structure code so these split cleanly.

## v0 scope

- **IN:** GET result (latest + commit), badge, `/capabilities`, blob cache, live-scan
  fallback via an in-process worker pool, token/rate manager.
- **OUT (deferred):** message broker (`gocloud.dev/pubsub`), warm-cache scheduler,
  analytics/index (DuckDB/Postgres/ClickHouse), signed-upload `POST` (Sigstore),
  request-level auth/multi-tenancy.

## v0 done =

`scorecard-mcp --base-url http://localhost:PORT get_repo_score <repo>` returns a
correct result: a cache **HIT** from a `fileblob` bucket, and a cache **MISS** that
triggers a live `scorecard.Run()`, populates the bucket, and serves it — with an
integration test proving both paths against `fileblob` and a self-hosted
S3-compatible store.

## Conventions

- Spec-driven via OpenSpec: explore -> propose -> design -> specs -> tasks ->
  implement. Keep specs and code in sync.
- Go: match the Scorecard toolchain version. If builds fail with a go tool version
  mismatch across many stdlib packages, a stray `GOROOT` is the cause — prefix
  commands with `env -u GOROOT`.
- Run `golangci-lint` before considering anything done; `go test ./...` clean.
- Commits: single atomic commit per logical change; DCO sign-off (`git commit -s`);
  trailer `Co-Authored-By: Claude <noreply@anthropic.com>`; detailed body. Feature
  branches only — never commit to `main`. Do not open PRs unless explicitly asked.
- OSS repo: no employer/internal references in files or commits. Internal deployment
  glue (object-store endpoints, org/repo scan lists, orchestration manifests, token
  sourcing) lives in a separate internal repo that deploys and feeds this server.

## Boundaries

- Reference client / acceptance test: `uwu-tools/scorecard-mcp`.
- Engine + `scorecard serve`: `github.com/ossf/scorecard`.
- Contract + blob reader + models: `github.com/ossf/scorecard-webapp`.
