# Acceptance: `scorecard-mcp` as the client

This is the **v0-done gate** (OpenSpec tasks group 8): prove that a real
[`uwu-tools/scorecard-mcp`](https://github.com/uwu-tools/scorecard-mcp) binary,
pointed at this server with `-base-url`, gets correct results for both a cache
**HIT** and a cache **MISS** that triggers a live scan. `scorecard-mcp` is a
stdio MCP server, so "the client" here is driven the same way a host (Claude
Desktop / VS Code) drives it — over `mcp.CommandTransport`, calling the
`get_repo_score` tool.

Last executed **2026-08-05** — HIT and live-MISS legs **pass** on `fileblob`.
The S3-compatible leg is deferred (needs Docker); see the bottom of this file.

## Prerequisites

- Go toolchain matching `go.mod` (1.25.x). Prefix Go commands with
  `env -u GOROOT` if a stray `GOROOT` breaks stdlib builds (see `AGENTS.md`).
- Network egress for the live-scan leg: a live scan calls the GitHub API and,
  on first use, fetches the OSS-Fuzz `status.json` (`clients/ossfuzz`). The
  server itself starts offline — the OSS-Fuzz client is created lazily
  (`ossfuzz.CreateOSSFuzzClient`, not the eager variant), so it does no
  network I/O until a scan actually runs, and cache HITs serve without any
  network access.
- An SCM token for the live-scan leg. Any of these works; the server reads a
  comma-separated pool and falls back to `GITHUB_AUTH_TOKEN`:

  ```sh
  export GITHUB_AUTH_TOKEN="$(gh auth token)"   # e.g. from the gh CLI
  ```

- A checkout of `scorecard-mcp` next to this repo (for the driver below).

Only `SCORECARD_RESULTS_BUCKET_URL` is required to boot; a missing token only
disables live scans (cache HITs still serve). See `internal/config`.

## Build

```sh
env -u GOROOT go build -o /tmp/scorecard-api ./cmd/scorecard-api
( cd ../../ossf/scorecard-mcp && env -u GOROOT go build -o /tmp/scorecard-mcp ./cmd/scorecard-mcp )
```

## Leg 1 — cache HIT on `fileblob`

Seed a bucket with a canonical JSON2 body (an authentic one from the public API
is convenient), start the server, and confirm the client reads it back.

```sh
BUCKET="$(mktemp -d)/bucket"
mkdir -p "$BUCKET/github.com/ossf/scorecard"
curl -sS -H 'Accept: application/json' \
  https://api.scorecard.dev/projects/github.com/ossf/scorecard \
  -o "$BUCKET/github.com/ossf/scorecard/results.json"

SCORECARD_RESULTS_BUCKET_URL="file://$BUCKET" SCORECARD_LISTEN_ADDR=":18080" \
  /tmp/scorecard-api &

# Contract sanity (served verbatim from the bucket):
curl -s localhost:18080/projects/github.com/ossf/scorecard | jq '.score, (.checks|length)'
curl -s localhost:18080/capabilities
curl -so /dev/null -w '%{http_code} %{content_type}\n' \
  localhost:18080/projects/github.com/ossf/scorecard/badge
```

Then drive the **real MCP client** against it (see the driver below):

```sh
go run . /tmp/scorecard-mcp http://localhost:18080   # calls get_repo_score
```

**Observed (2026-08-05):** `get_repo_score ossf/scorecard` → `score 8.9`, 18
checks, `attribution.source_url = http://localhost:18080` (i.e. read from this
server, not the public API). Route matrix: `/projects/...` → `200`;
`/capabilities` → `200` (`mode: cached+live`, `requires_opt_in: false`);
`/badge` → `200 image/svg+xml`; unknown repo → `404`; `?commit=nothex` → `400`.

## Leg 2 — cache MISS → live scan → persist → serve

Point the server at an **empty** bucket (with a token) and request an
un-cached repo. Raise the sync timeout so the first request blocks for the scan
and returns `200` (otherwise it returns `202` + `Retry-After` and the client
re-requests).

```sh
BUCKET="$(mktemp -d)/bucket"; mkdir -p "$BUCKET"
SCORECARD_RESULTS_BUCKET_URL="file://$BUCKET" SCORECARD_LISTEN_ADDR=":18081" \
  SCORECARD_SYNC_TIMEOUT=150s SCORECARD_SCAN_TIMEOUT=200s \
  GITHUB_AUTH_TOKEN="$(gh auth token)" /tmp/scorecard-api &

time curl -s localhost:18081/projects/github.com/uwu-tools/scorecard-mcp | jq .score
find "$BUCKET" -name results.json          # both keys should now exist
time curl -s localhost:18081/projects/github.com/uwu-tools/scorecard-mcp | jq .score  # fast HIT
```

**Observed (2026-08-05):** first request `200` in ~10s (`score 6.5`, 18 checks);
the bucket gained **both** the `latest` pointer
(`.../scorecard-mcp/results.json`) and the commit-pinned object
(`.../scorecard-mcp/<sha>/results.json`) — the D4 dual-write. The re-request
returned in **~30ms** (cache HIT), and `?commit=<sha>` also HITs (immutable,
D5). The MCP `get_repo_score` on the same repo returns the live-produced result.

## Driver (throwaway MCP client)

`scorecard-mcp` has no scoring CLI — it speaks MCP over stdio. This mirrors its
own `cmd/scorecard-mcp/integration_test.go`. Drop it in a temp dir **inside the
`scorecard-mcp` module** (so it resolves the go-sdk dependency), `go run .`, then
delete it — do not commit it into either repo.

```go
package main

import (
	"context"; "encoding/json"; "fmt"; "os"; "os/exec"; "time"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	bin, baseURL := os.Args[1], os.Args[2]
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client := mcp.NewClient(&mcp.Implementation{Name: "acceptance", Version: "0"}, nil)
	cs, err := client.Connect(ctx, &mcp.CommandTransport{
		Command: exec.CommandContext(ctx, bin, "-base-url", baseURL),
	}, nil)
	if err != nil { fmt.Println("connect:", err); os.Exit(1) }
	defer func() { _ = cs.Close() }()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "get_repo_score", Arguments: map[string]any{"repo": "ossf/scorecard"},
	})
	if err != nil || res.IsError { fmt.Println("call failed:", err, res); os.Exit(1) }
	b, _ := json.MarshalIndent(res.StructuredContent, "", "  ")
	fmt.Println(string(b))
}
```

## Known gap (task 8.3): the MCP still reports cached-public caveats

The server advertises correct provenance at `/capabilities`
(`mode: cached+live`, `requires_opt_in: false`, on-demand caveats). But
`scorecard-mcp`'s `CachedRESTProvider` (`internal/provider/rest.go`)
**hardcodes** the public-cache caveats ("opted in via `publish_results: true`",
"weekly scan omits CI-Tests / Contributors / Dependency-Update-Tool") and a
`source` of `cached-rest`, regardless of which backend it points at. So a client
pointed at this server currently **misreports** its provenance.

This is the motivation for `/capabilities` (design **D7**). The fix — teach
`scorecard-mcp` to read `/capabilities` instead of hardcoding — lives in the
`scorecard-mcp` repo, not here. Verified server-side; MCP-side reader is the
tracked follow-up.

## Deferred: the S3-compatible leg

`gocloud.dev`'s `s3blob` driver serves any S3-compatible store. The
only change from Leg 1/2 is the bucket URL and credentials, e.g.:

```sh
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=secret
export SCORECARD_RESULTS_BUCKET_URL="s3://scorecard-results?region=us-east-1&endpoint=http://localhost:8333&hostname_immutable=true&use_path_style=true"
```

Running a local S3-compatible store needs Docker, which was unavailable at last
execution. This leg is outstanding for full 9.3 sign-off; the store already has
an S3-compatible integration test gated on `SCORECARD_TEST_S3_URL` (task 3.5).

**Verified 2026-08-05:** `TestRoundTripS3` passes against the local
`docker-compose.s3.yml` store using this exact bucket URL — see memory
`scorecard-api-docker-compose`.
