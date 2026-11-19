# Design: Report the results API's build at `/version`

Decision IDs are **I\*** here, distinct from the other changes' **A\***,
**B\***, **C\***, **D\***, **E\***, **F\***, **L\***, **V\***, and **W\***.

## Decisions

### I1 — Three fields: release, commit, parser

`version` and `commit` name the artifact, the same values the image's
`org.opencontainers.image.version` label and `sha-` tag carry. `parser` is the
one dependency whose version decides which workflows verify, which is what
ossf/scorecard#5322 turned on.

There is no `engine` field. `go version -m` on the API binary shows it links
`actionlint.kjanat.dev` but not `github.com/ossf/scorecard/v5`. An engine
version reported by the API would describe code it doesn't run.

### I2 — A documented route, cached by the CDN

With the migration quarantine lifted, `openapi.yaml` can document the route
like any other, and go-swagger generates its responder. The response follows
the existing routes' cache pattern:

- **`Surrogate-Control: max-age=300`.** Fastly absorbs repeats: about one
  origin hit per cache node per five minutes.
- **`Cache-Control: max-age=60`.** Browsers and scripts recheck often enough
  to notice a deploy.
- **`Surrogate-Key: scorecard-version`.** A deploy can purge it if five
  minutes matters.

An abusive flood costs less here than against `/projects/…`, whose cache
misses read S3. This route does no I/O at all.

Post-deploy checks go through the CDN like everything else: purge the
surrogate key, or wait out the five minutes. Documenting a way around the CDN
would advertise the origin, whose direct use is discouraged.

### I3 — Link-time identity, run-time parser version

The Docker build excludes `.git`, so neither `git describe` nor the Go
toolchain's VCS stamping works inside it. `publish-images.yml` already resolves
`GIT_VERSION` and `GIT_HASH` outside the build and passes them as build args,
which the API's Dockerfile used to ignore. `api/Makefile` now links them with
`-X`, ahead of its trailing `-extldflags`, which would otherwise take the next
word as its value. Empty values read `unknown` rather than an empty string.

The parser version is read from `runtime/debug.ReadBuildInfo` and follows any
`replace` directive, so the response reports what was actually linked. All of
this is computed once per process.
