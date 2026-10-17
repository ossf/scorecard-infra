# Tasks: Report the results API's build at `/version`

## 1. Contract and handler

- [x] 1.1 Add `/version` and `VersionInfo` to `api/openapi.yaml`; regenerate
      with the pinned go-swagger (**I2**).
- [x] 1.2 `api/app/server/version.go`: link-time `gitVersion`/`gitCommit`,
      parser version from build info, computed once (**I3**).
- [x] 1.3 Wire `GetVersionHandler` in `configure_scorecard.go`.

## 2. Build

- [x] 2.1 `api/Dockerfile` accepts `GIT_VERSION` and `GIT_HASH`;
      `api/Makefile` links them with `-X` ahead of `-extldflags` (**I3**).

## 3. Documentation

- [x] 3.1 `api/README.md`: the route, and drop the stale gateway wording
      about `openapi.yaml`.
- [x] 3.2 `deploy/api/README.md`: check `api.scorecard.dev/version` after an
      apply, purging the surrogate key first.

## 4. Verification

- [x] 4.1 Unit tests: release build, nothing injected, replaced parser,
      parser not linked, no build info; the handler's headers and payload.
      Under Go 1.26.5, CI's toolchain, a test binary's build info lists no
      dependencies, so the handler test can't assert a real parser version.
- [x] 4.2 Built with `api/Makefile` and injected values, ran it, and queried
      `/version`: injected release and commit, `actionlint.kjanat.dev
      v1.17.0`, and the three cache headers. Rebuilt without the values:
      both read `unknown`. `go version -m` on binaries built with Go 1.26.5
      (CI's toolchain) and 1.27.1 both list the parser.
- [x] 4.3 After merge, confirm `main`'s published `scorecard-api` image
      carries the commit (a local Docker build couldn't reach Docker Hub).
      **Done 2026-10-14:** the binary in `scorecard-api:sha-5c445f8…`
      contains the full commit and `5c445f8` as its version, and links
      `actionlint.kjanat.dev v1.17.0`.
- [x] 4.4 After the next release is deployed, `api.scorecard.dev/version`
      reports it.
      **Done 2026-10-14:** `v0.3.0` deployed as task definition revision 4.
      `/version` returns `v0.3.0`, `8fb4a1b…`, and
      `actionlint.kjanat.dev v1.17.0` through the CDN. The first request
      landed on a `v0.2.0` task mid-rollout, and Fastly cached its 404
      under its default TTL. That one URL needed a manual purge, which only
      happens once, when a route is introduced.
