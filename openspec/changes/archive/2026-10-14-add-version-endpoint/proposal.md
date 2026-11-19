# Proposal: Report the results API's build at `/version`

## Why

Nothing the results API returns says which build produced it. When curl's
uploads started failing with HTTP 400
([ossf/scorecard#5322](https://github.com/ossf/scorecard/issues/5322)), the
deciding fact was which workflow parser production ran. Finding that took
reading ECS task definitions and image digests. During the `v0.2.0` deploy,
HTTP couldn't tell old tasks from new ones either.

scorecard-action's planned canary also needs this to check that the template it
publishes is accepted by the API version actually deployed.

## What Changes

- **`GET /version`**, documented in `api/openapi.yaml`, returns `version`
  (the scorecard-infra release, or `git describe` output for other builds),
  `commit`, and `parser` (the workflow parser module and version) (**I1**).
- **The CDN caches it** for five minutes under the `scorecard-version`
  surrogate key, and browsers for one minute. Each origin hit is a tiny
  in-memory response computed once at startup (**I2**).
- **Build identity is injected at link time.** `api/Dockerfile` takes the
  `GIT_VERSION` and `GIT_HASH` build args `publish-images.yml` already passes,
  and `api/Makefile` links them in. Without them, both read `unknown` (**I3**).
- **The parser version comes from the binary's build information**, so it
  can't drift from what is linked (**I3**).
- Document the route in `api/README.md`, and a post-deploy check in
  `deploy/api/README.md`.

## Capabilities

- **api-version** (new) — the results API reports the build it is running.

## Impact

- `api/openapi.yaml` and the regenerated `api/app/generated/` tree
- `api/app/generated/restapi/configure_scorecard.go` (handler wiring)
- `api/app/server/version.go`, `version_test.go` (new)
- `api/Makefile`, `api/Dockerfile`
- `api/README.md`, `deploy/api/README.md`

The API image changes only in the metadata it carries and the new route.

## Non-goals

- **Reporting the Scorecard engine version.** The API binary doesn't link
  the engine, so it has no engine version to report (**I1**). The image's
  `dev.scorecard.engine.*` labels record the module-wide version.
- **A response header on every request.** Cached responses would report the
  build that produced them, not the one serving.
- **Purging the key on deploy automatically.** A manual purge, or waiting
  five minutes, is enough for something that changes once a release.
