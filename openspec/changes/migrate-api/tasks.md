# Tasks: Migrate the results API out of ossf/scorecard-webapp

Groups map to the migration's phases. Each group is independently reviewable and
independently revertible. **Group 7 MUST NOT begin until group 6 has held clean
for the agreed period** (**W11**).

Counts below are gates, not estimates: they come from the analysis basis
(`ossf/scorecard-webapp` `main` @ `39c800b`) and a deviation means the filter
selected the wrong thing.

## 0. Pre-work / decisions

- [x] 0.1 **One external importer found, and it does not block a clean delete.**
      `jetstack/tally` imports `app/generated/models` from four of its packages —
      the predicted consumer (**W12**). Nothing imports the generated client, the
      `restapi` package, or the module root. But tally depends on
      `github.com/ossf/scorecard-webapp v1.0.5`, a *released version*, and the
      module proxy holds all 20 published versions immutably
      (`v1.0.5` resolves with its commit hash, independent of the repository's
      state). Deleting `go.mod` from upstream `main` therefore breaks
      `@latest`/`@main` resolution and new consumers, not pinned builds. tally is
      also dormant — last push 2023-11-13, still on `scorecard/v4`.
      **Conclusion: clean delete is safe, with one added obligation — upstream's
      release tags must not be deleted** (task 7.9). No deprecation window.
- [x] 0.2 **Confirmed as part of 1.3.** The `--dry-run` pass that filtered
      the API path set verified `re` is available in the `--message-callback`
      context without an explicit import (**W1**).
- [x] 0.3 **Confirmed as part of 1.3, the hard way.** The first filter attempt
      assumed `--path Makefile` selects `Makefile.swagger` by string prefix; it
      does not. The corrected behavior is recorded in **W1**, and the second run
      selected and relocated `Makefile.swagger` as intended and nothing else.
- [x] 0.4 **Decided: match the checked-in tree.** Regeneration must be a no-op,
      so the Phase 3 diff stays empty and the import stays a pure relocation.
      Toolchain currency is a separate concern from a migration whose acceptance
      test is that nothing changed.
- [x] 0.4a **Recover the generator version, because nobody wrote it down.** The
      generated files carry no version stamp and the webapp pins go-swagger
      nowhere — its `Makefile` invokes whatever `swagger` is on `PATH`, the same
      unpinned-tool problem the pipeline import hit with `protoc`. Bisect
      go-swagger releases current around 2026-02-05 (`395f1f1`, the last commit
      to regenerate the tree) until `make swagger` produces no diff, then pin
      that version where CI enforces it. If no release reproduces the tree
      exactly, say so and escalate to 0.4 rather than accepting a small diff
      quietly — a tree nobody can regenerate is a tree nobody can safely change.
      **Resolved 2026-08-30, not by bisection.** The bisect-to-exact-match step
      was never run; [PR #69](https://github.com/ossf/scorecard-infra/pull/69)
      instead pinned forward to go-swagger **v0.36.5** (`SWAGGER_VERSION` in
      `Makefile`), inlining several `openapi.yaml` schema references the newer
      generator no longer honors. That is a deliberate diff from the pre-import
      tree, not the exact reproduction this task originally asked for — but it
      is pinned, and `make api-swagger` is now a no-op against it, which is
      what the rest of this task's language ("nothing to regenerate with")
      needed to unblock. Treated as resolving this task rather than escalating
      to 0.4, per Stephen.
- [x] 0.5 **Decided: administrative override.** 37 imported commits carry no
      sign-off and no honest code fix exists (**W13**). Same resolution the
      pipeline import reached, agreed in advance this time rather than at merge.
      Record who applied it and on which pull request.
- [ ] 0.6 Confirm ownership and admin access for every external system to be
      repointed: Cloud Build trigger, Cloud Run service, Cloud Endpoints service
      configuration, domain mapping, Fastly, and the `scorecard-web` OSS-Fuzz
      project (**W8**/**W11**).
- [x] 0.7 **Confirmed 2026-08-30: AboutCode's AWS account**, per Stephen.
      This repo's OpenTofu is the sole way that account is changed.
- [x] 0.8 Obtain approvals: Scorecard Steering Committee and GCP project admin.
      Ask the committee whether it wants a standalone summary rather than this
      OpenSpec change as the artifact.
      **Approved 2026-08-30.** Stephen approves as GCP project admin, on top of
      the Steering Committee involvement already noted. The standalone-summary-
      vs-OpenSpec-artifact question remains unasked.

## 1. History extraction, reviewed in isolation

**Nothing is pushed to `ossf/scorecard-infra` in this group.**

- [x] 1.1 Cloned `ossf/scorecard-webapp` fresh and single-branch to
      `../scorecard-api-extract`; tip `39c800b`, 653 commits, 20 tags — matching
      the analysis basis exactly (**W1**).
- [x] 1.2 Deleted all 20 tags in the clone before filtering (**W2**).
- [x] 1.3 Ran `git filter-repo` over the API path set with the `api/` renames
      and the `(#N)` → `(ossf/scorecard-webapp#N)` rewrite (**W1**/**W3**).
      `docs/dns.md` retained unrenamed (**W6**). The `--dry-run` confirmed `re`
      is available in the `--message-callback` context without an explicit
      import (0.2). **Took two attempts:** the first omitted `Makefile.swagger`
      on the mistaken theory that `--path Makefile` selects it by string prefix.
      It does not — see the corrected caution in **W1**.
- [x] 1.4 Gate passed — **150 commits, 0 merge commits**, exactly as
      predicted.
- [x] 1.5 Gate passed on the second run — **117 files**, 116 under `api/` plus
      `docs/dns.md`, diffed file-by-file against the expected list rather than
      counted. The first run's 116 is what surfaced the `Makefile.swagger`
      defect; a count-only check would have found it, but the diff is what named
      it.
- [x] 1.6 Gate passed — **0 tags**.
- [x] 1.7 Gate passed — `api/app/server/get_results.go` follows 9 commits back
      through the 2022 go-swagger restructure into `app/get_results.go`.
      `api/app/server/post_results_test.go` follows 14 commits back through
      **two** renames: `app/signing_test.go` → `app/post_results_test.go` →
      `app/server/post_results_test.go`.
- [x] 1.8 Gate passed — blame on `api/app/server/post_results.go` attributes to
      Azeem Shaikh (404 lines), Spencer Schrock (165), Piotr P. Karwasz, Naveen,
      asraa and others; nothing to the filter.
- [x] 1.9 Gate passed — **0 bare `(#N)` references remain**; 140 commits carry
      rewritten `(ossf/scorecard-webapp#N)` references. History spans 2021-12-29
      to 2026-08-07 across 12 authors.
- [x] 1.10 Confirmed — the both-halves commit (`b7e0f8d` upstream, `2474424`
      after filtering) survives with 47 API-side files changed and no site
      content. Not empty.

## 2. Graft into scorecard-infra

- [x] 2.1 Branch `import-api` created off `main` at `5b90e6f`; filtered history
      merged with `--allow-unrelated-histories`, conflict-free as predicted (117
      files staged, no conflicts). Repo now at 690 commits and **three roots**
      (**W14**).
- [x] 2.2 Verified — rename tracking and blame survive the merge. Re-running
      1.7 against the merged branch still resolves `post_results_test.go` 14
      commits back through both renames, and `get_results.go` 9 commits back.
- [x] 2.3 Verified — zero tags arrived with the merge.
- [x] 2.4 Extraction remote removed. Branch is **local and unpushed** — the
      filtered result at `../scorecard-api-extract` and this branch are both
      reviewable before anything reaches the remote.
- [x] 2.5 `api/initial-graft.md` written, following `cron/initial-graft.md`.
      Records the import's terms and stats, the per-file reason each unimported
      thing stayed behind — which differs from the pipeline's case, where the
      obstacle was uniformly "shared with the engine" — and the originating
      commits. Notes that `main.yml` and `.golangci.yml` landed upstream on the
      same day in June 2022, six months after the repository was created: the API
      ran without CI or a linter for its first several months, which is worth
      knowing before reading an early commit's style as deliberate.

## 3. Make it build

- [x] 3.1 Import paths rewritten in 18 Go files. Every occurrence was a module
      prefix; nothing needed hand-inspection (**W4**).
- [x] 3.2 Non-Go references fixed — **and the W4 table over-predicted.** Because
      the whole tree moved together and its recipes are relative to it, the
      Makefile prerequisites, the swagger generate paths, the `SWAGGER_GEN` find
      expression and the `//go:generate` directive are all still correct
      unchanged. Only two things genuinely broke, both because the module root is
      now two levels up: the Dockerfile (`make -C api`, and the binary copied
      from `src/api/`) and the Makefile's docker target (build context `..`).
      Upstream's `linter` target was dropped — it invoked a `.golangci.yml` that
      **W7** deliberately did not import, so it referenced a file that does not
      exist. Root Makefile gains `api-build` / `api-swagger` / `api-docker`
      delegating targets. Surviving `scorecard-webapp` strings are the binary
      name (**W5**) and upstream test-fixture repository names, both correct.
- [x] 3.3 `docs/dns.md` trimmed to the API half, with a note recording that it
      arrived whole and that the website half stays upstream (**W6**).
- [x] 3.4 `go.mod` seeded with the webapp's 21 direct requirements **at their
      pinned versions** before tidying, so the imported code builds against what
      production runs rather than whatever resolved latest. **20 of 21 held
      exactly.** The one that moved — `AdaLogics/go-fuzz-headers` — moved because
      this module already required a newer revision; MVS max, unavoidable.
      `gocloud.dev` was already at v0.46.0 here, matching the webapp exactly.
      MVS also nudged some pre-existing indirect deps (`actionlint` v1.7.9 →
      v1.7.12, `x/net` v0.56.0 → v0.58.0, `x/mod` v0.37.0 → v0.39.0 and similar).
      `actionlint` is the one worth noting: the Scorecard engine links it, and
      `cron/` is behavior-frozen — the bump is a consequence of two projects
      sharing one module, not a choice.
- [x] 3.5 `.golangci.yml` reconciled (**W7**). 41 issues, **all** explained by
      config lineage rather than by defects: the webapp ran `default: none` with
      an explicit enable list, this config descends from `ossf/scorecard`'s and
      enables strictly more. All of it was in hand-written source, so the
      generated-path exclusion the task anticipated would not have reached any of
      it. Resolved by applying the imported tree's own historical linter set to
      `api/` only, with the block marked for removal when the freeze lifts (5.7).
      No linter is disabled repository-wide.
      **`govet` was deliberately left enabled**, and it earned it — see 3.8.
- [x] 3.6 Verified clean both directions — `api/` imports nothing from
      `internal/`, `cmd/`, or `cron/`, and none of them imports `api/` (**W10**).
- [x] 3.7 Blocked on 0.4a, which trails past this week: the generator version
      that produced the checked-in tree is unrecorded, so there is nothing to
      regenerate *with* yet. `make api-swagger` exists and is wired.
      **Unblocked by 0.4a's resolution** — go-swagger is pinned
      (`SWAGGER_VERSION = v0.36.5`) and `make api-swagger` regenerates against
      it cleanly.
- [x] 3.8 `go build ./...` and `golangci-lint run ./...` are clean with all
      three trees included. `go test ./... -race` is clean **except** for the
      imported end-to-end specs, which reach the network — see 3.8a and 3.8b.
      Leaving `govet` enabled for `api/` caught a real defect that would
      otherwise have shipped: a non-constant format string in `api/main.go`.
      It is not a lint opinion — `go test` runs the vet printf check, so the
      package **failed to build under test**. Upstream never saw it because its
      CI only ever ran `cd app/server && go test`, never the root package.
      Fixed to `fmt.Fprint`, matching the adjacent line and provably identical
      output for the current string. First deliberate deviation from the
      behavior freeze, and a narrow one.
- [x] 3.8a **Resolved: the GitHub-API e2e specs need a token, and with one they
      pass.** `githubVerifier_contains` calls `api.github.com`; unauthenticated it
      hits the 60/hour per-IP limit and was red one local run in three. Fixed by
      supplying `github.token` in CI (4.3). **Verified in CI (PR #49): all specs
      pass.** This is what **W9** predicted, and the fix was configuration.
- [x] 3.8b **Corrected. The Sigstore verification specs do run, and they pass.**
      An earlier note here claimed all five skipped unconditionally because Rekor
      v2 removed the search-by-hash index, and concluded the publish path's
      certificate verification had no working end-to-end coverage anywhere. That
      was wrong, and it was wrong in the direction that matters — it understated
      existing coverage and would have justified skipping verification work.
      **CI reports 8 passed, 0 skipped** (PR #49), at 64.6% statement coverage
      for `api/app/server`.
      The local result — 3 passed, 5 skipped — was an artifact of this authoring
      environment: it receives an HTML `403` from *every* Rekor endpoint,
      including `/api/v1/log`, so the block is a network proxy rather than a
      removed API. The upstream skip guard is real and its comment does cite
      Rekor v2, so the coverage may still be intermittent for other consumers —
      but it is present and green today.
      Task 6.6 (confirm a real Action upload end to end) is therefore ordinary
      cutover verification again, not the sole check standing in for absent
      coverage.
- [x] 3.9 Binary builds via `make api-build`, starts, and serves. The badge
      path returns `302` to `img.shields.io` correctly — it is a pure redirect
      with no storage access, contrary to the AWS memo's description of it as
      generating badges. `/projects/{host}/{org}/{repo}` returns `404` without
      GCS credentials, which is the read path failing closed rather than
      erroring; it cannot be exercised further locally.
- [x] 3.10 Confirmed — the imported binary is still named `scorecard-webapp` and the
      incubator's is still `scorecard-api` (**W5**). The names invert reality and
      renaming is tempting while the Dockerfile is open — but it changes image
      contents, and image equivalence is the cutover gate. Rename after 6.7.

## 4. CI and image builds, in parallel with production

**Production still runs images built from `ossf/scorecard-webapp` throughout.**

- [x] 4.1 `api-docker` added to `build-images.yml`'s matrix. **Verified in CI
      (PR #49): the image builds, in 2m0s.** It could not be built locally — the
      Docker daemon here cannot reach `registry-1.docker.io` (TLS handshake
      timeout on a direct pull, nothing cached), the same interception the
      pipeline import hit. So the Dockerfile path fixes from 3.2 were unproven
      until this run, which is exactly the defect class that only an image build
      catches.
- [x] 4.2 `license-headers` job added, using `-check` (report, don't rewrite)
      rather than upstream's rewrite-then-`git diff` pair. **Scoped to `api/`:**
      run repository-wide it flags four pre-existing files —
      `.github/dependabot.yml` and three workflows — that have no header and
      nothing to do with this import. Widening it is a separate change.
- [x] 4.3 `GITHUB_AUTH_TOKEN: ${{ github.token }}` added to the test job, fixing
      the rate-limit flake in 3.8a. **Verified in CI (PR #49): 8 specs pass, 0
      skip**, `api/app/server` at 64.6% statement coverage.
- [x] 4.4 Blocked on 0.4a, same as 3.7: there is no pinned generator to check
      against yet.
      **Satisfied by [PR #69](https://github.com/ossf/scorecard-infra/pull/69).**
      Its `swagger-verify` CI job installs the pinned go-swagger version and
      fails if `make api-swagger` is not a no-op against the committed spec —
      exactly the check this task was blocked on having something to check.
- [ ] 4.5 Deferred with the OSS-Fuzz repointing, per the scope call for this
      week. Porting the workflow alone would leave fuzzing pointed at the old
      source anyway.
- [x] 4.6 `/api` added to `.github/dependabot.yml` as its own docker entry.
      Kept separate from the pipeline glob and the API server's root entry for
      the reason those two are already separate: it is a third `golang` tag
      lineage, and a shared group keyed on dependency name would collapse
      unrelated bumps into one pull request.
- [x] 4.7 `import-edges` job added — **there was no existing check to match.**
      The task assumed one guarded `cron/`; what exists is a checkbox in the
      pull-request template, which is a promise rather than a guard. The job
      covers both frozen trees and both directions, since excluding `cron/`
      from the same three-line script would have been artificial. Verified twice:
      it passes on the current tree, and it exits 1 on a planted violation. A
      guard that has never been seen to fail is not yet a guard.
- [x] 4.8 **Measured from PR #49.** Presubmits wall clock is ~4m15s, set by the
      `test` job — which is also where the API landed, since its end-to-end specs
      are network-bound. The two new jobs are not on the critical path
      (`license-headers` 35s, `import-edges` 17s) and `build`/`lint` finish at
      3m33s/3m50s. Image builds are a separate ~3m51s path, set by
      `cron-controller-docker`; `api-docker` is among the faster targets at 2m0s.
      Net effect of adding the API: no change to the critical path's shape, and
      one more image build running in parallel with six others.
- [x] 4.9 Release trigger is `api/vX.Y.Z`, implemented in
      `publish-api-image.yml` and documented in its header with the reasoning —
      two deployables here, and upstream's `v1.x` must keep resolving for the
      module's remaining consumer, so a bare version tag would be ambiguous in
      two directions.
- [x] 4.10 **Pulled forward rather than filed as a follow-up**, because the
      cutover is now a handoff rather than a GCP-to-GCP repoint: the image has to
      be pullable by an operator with no access to the GCP project that builds it
      today. `publish-api-image.yml` builds and pushes to `ghcr.io` on an
      `api/v*` tag or manual dispatch, with provenance and an SBOM, and writes
      the digest to the job summary so a handoff can quote it rather than
      rediscover it. Deploy the digest, not a tag.
      **Not verified:** no push has happened, so this workflow has never run.

## 5. Documentation and repository identity

- [x] 5.1 `docs/upstream-graft.md` rewritten around consolidation. Opens by
      saying what it used to claim and why that inverted, so a returning reader
      is not left reconciling two documents from memory. States which server
      ships and why; narrows the still-graftable list to `/capabilities` (**D7**)
      plus a deferred cache seam; and keeps a *Rationales that stopped holding*
      section rather than deleting the arguments that expired — including
      **D13**'s and "keep the handlers thin so they lift out cleanly", which now
      has nowhere to lift out to.
- [x] 5.2 `AGENTS.md` updated: four parts in a table, a "Which API server
      ships" section, a **Quarantined: do not "fix" these** section naming the
      `gs://` constants, the `x-google-backend` block, `cron/`'s GCS write path,
      and the scoped linter block. Plus an `api/` tree section covering the
      hand-owned `configure_scorecard.go`, the thin end-to-end coverage, and why
      the binary names are inverted.
- [x] 5.3 `openspec/config.yaml` context rewritten for the three code trees,
      which one ships, the enforced import-edge rule, the inbound direction of
      travel, and the quarantined violations.
- [x] 5.4 `README.md` gains a **Results API (api.scorecard.dev)** section —
      tree map, endpoints, make targets, the ghcr publish path — and its
      *About The Project* table now lists four parts with accurate states. The
      pre-existing "This server is an incubator, not a permanent fork" claim
      above the API-server section was false as written and is replaced with a
      note that it is not the deployment path.
- [x] 5.5 `internal/httpapi`'s package doc gains a **Status: not the deployment
      path** section — what ships instead, why, that the package is retained
      deliberately rather than abandoned, and that the honest options later are to
      converge or remove it rather than maintain it indefinitely.
- [x] 5.6 `internal/model`'s doc records that **half of D13's premise expired**:
      the generated models are no longer only upstream, and go-openapi is a direct
      dependency of this module now regardless. The remaining argument is narrower
      and stated as such — depending on those models would couple the cache path
      to a tree CI forbids importing.
- [x] 5.7 **Remove the `api/` linter-exclusion block from `.golangci.yml` when
      the behavior freeze lifts**, and fix what it surfaces. Removed the `api/`
      linter exclusions block covering err113, errcheck, errorlint, gocognit,
      gocritic, nolintlint, testifylint, and wrapcheck. Addressed all surfaced
      warnings across `api/`: wrapped static sentinel errors, decomposed verify workflow
      helpers to reduce cognitive complexity, passed certInfo by pointer, handled
      deferred and unhandled error checks, and cleaned unused directives.
      Repository-wide `golangci-lint run ./...` verified clean (0 issues).

## 6. Production cutover

- [x] 6.0 Capture the before-state of every external system (**W11**).
      **Script written, not run:** `scripts/cutover/capture-config.sh` covers
      Cloud Build triggers, the Cloud Run service and its revisions (the
      rollback targets), the deployed Endpoints config, domain mappings, DNS
      records with their TTLs, IAM, bucket metadata, and Secret Manager entries
      by name. It is best-effort per section — a permission failure records
      itself and the run continues, because a partial capture is useful and an
      aborted one is not — and it redacts probable inline credentials.
      **Unverified: this environment has no gcloud and no credentials**, so the
      resource names are informed guesses from `api/openapi.yaml`,
      `api/Dockerfile`, and `docs/dns.md`. Expect to correct some; the FAILED
      markers in its summary are where to look. Fastly and OSS-Fuzz are listed
      as explicitly manual.
      This is the task whose cost rises fastest with delay: none of it is in
      git, and it stops being readable when project access lapses.
      **First real run (2026-08-25) failed on expired gcloud credentials** —
      `Reauthentication failed. cannot prompt during non-interactive execution`
      — and exposed two defects in the script rather than anything about the
      project. Both fixed and tested against a stubbed `gcloud`:
      it now fails fast on missing credentials instead of reporting the same
      auth error fifteen times and burying the one instruction that fixes it;
      and it defaults to a timestamped, gitignored directory and refuses a
      repository root, because passing `.` scattered a dozen loose files into
      the working tree.
      **Second run captured 13 of 16 sections.** What it established, most of
      which contradicts an assumption somewhere in this change:
      * **Three Cloud Run services, not one.** `scorecard-api-prod`,
        `scorecard-api-staging` — which already exists, so W11's "deploy
        somewhere non-production" has a home — and `scorecard-endpoints-prod`,
        the ESPv2 gateway. Capturing only the first described a third of the
        request path.
      * **Only one Endpoints service exists**, for `api.securityscorecards.dev`.
        There is none for `api.scorecard.dev`, so the two hostnames do not reach
        the backend by the same path.
      * **The gateway enforces a 2023-08-30 config.** `openapi.yaml` gained 31
        lines in February 2026 (`395f1f1`, the Fastly cache headers) that were
        never deployed. W10 treats the contract as live deployment
        configuration; it is, but latently — nobody has redeployed it in three
        years.
      * **`API_BASE_URL=https://api.scorecard.dev`** and `FASTLY_PURGE_TOKEN`
        from the `fastly_purge_token` secret. This confirms 6.3a's single-purge
        diagnosis from configuration rather than inference.
      * Serving revision `scorecard-api-prod-00056-59d` (100%), 1 vCPU / 512Mi,
        concurrency 120, maxScale 1000, ingress `all`, running as the project's
        **default compute service account** — worth sizing and scoping the AWS
        equivalent against, and worth not reproducing the default-SA breadth.
      * Real DNS zone names are `scorecard` and `scorecard-existing`; my guesses
        from the domain names produced two 404s. Fixed, and the corrected run
        captured **18 of 19 sections**.
      * The one remaining failure, Cloud Run domain mappings, was **dropped
        rather than fixed a third time**: the DNS capture proved no domain
        mapping is in the request path (6.3c), so there was nothing to capture.
        Two wrong invocations were two more than the question deserved.
      **Complete: 18 of 19 sections, the 19th confirmed not applicable.**
- [ ] 6.0a **Gap: the capture never looked at Kubernetes, and that is where the
      credentials are.** `capture-config.sh` enumerates Cloud Run, Cloud Build,
      Endpoints, DNS, IAM, buckets, and Secret Manager. It has no GKE section.
      Secret Manager in this project holds exactly **one** entry,
      `fastly_purge_token` — which reads as a complete answer until you notice
      the scanning side authenticates to GitHub as an App, and that credential
      is not there. It is a Kubernetes Secret inside a cluster in the same
      project. The earlier capture was not wrong; it was looking at a different
      layer, and "18 of 19 sections" described coverage of the layer it knew
      about.
      Follow-on: `scripts/cutover/capture-gke.sh` walks every cluster in the
      project and, per namespace, captures Secrets, ConfigMaps, and workload
      manifests, with an `INDEX.tsv` inventory across all of them.
      **This one writes credential values to disk, unlike its two siblings** —
      `capture-config.sh` redacts anything resembling a secret, which is exactly
      backwards here, because a credential that cannot be replayed into the new
      environment has not been migrated. So the output directory is mode 0700,
      the run sets `umask 077`, and the summary says to move the contents into a
      real secret store and delete it. Base64 is an encoding, not encryption.
      Where re-issuing is cheap it beats transplanting: the point of capturing a
      GitHub App private key is that a rotation delay does not become an outage,
      not that rotation can be skipped.
      Two deliberate choices: **nothing is filtered** — service-account token
      Secrets are cluster-bound and worthless post-shutdown, but they are
      captured and flagged in the index rather than dropped, because omitting
      rows from an unrepeatable capture is the more expensive mistake — and it
      uses a scratch `KUBECONFIG` rather than letting `get-credentials` rewrite
      the operator's `~/.kube/config` and switch their current context.
      Written against a credential-less environment, where it could only be
      shown to parse under bash 3.2 and to fail fast on both prerequisites —
      which is how the second one surfaced: `gke-gcloud-auth-plugin` was not
      installed, and without it `kubectl` cannot reach GKE at all while naming
      neither the plugin nor the fix.
      **First real run (2026-08-28) captured one cluster of two, and not the
      one it was written for.** The project holds `criticality-score` and
      `openssf`. `criticality-score` came back complete — 7 namespaces, 41
      objects, mostly cluster-bound service-account tokens — and it belongs to
      a different OpenSSF hosted service that also dies with this account, so
      someone should own it, but it is not this change's business and holds
      nothing the API needs.
      **`openssf` failed at the first API call**, and that is the cluster whose
      name matches the project and the likelier home for the GitHub App
      credentials. So the gap this task exists to close is still open.
      **The script threw the reason away.** `kubectl get namespaces` ran with
      stderr redirected to `/dev/null`, so the run reported "could not list
      namespaces" and nothing else — and a private endpoint, a missing RBAC
      binding, and a stopped cluster are three different problems with three
      different fixes. The same mistake as discarding `dig`'s diagnostics in
      6.3d, in a different script: the error text *is* the finding.
      Fixed, and two related things with it. The failure is now reported with
      its message, an `INCOMPLETE` block names every uncaptured cluster *before*
      the inventory rather than after — twenty `ok` lines above one `FAILED`
      reads as success — and the script exits nonzero, so "the capture ran" and
      "the capture is complete" cannot be confused by anything checking status.
      **Second run (2026-08-28) got both clusters: 87 objects.** The cause was
      the VPN — the GKE control plane is not reachable through it. Worth
      writing down because it is the second tool in this task list to fail that
      way and the failure looks nothing like a network problem from inside: the
      DNS check needed the VPN off too. Try disconnecting before diagnosing
      anything subtler.
      `openssf` carries a `gitcache` namespace alongside `default`, which is
      the scanning side's own workload rather than anything GKE created.
      **The whole haul is six secrets.** 87 objects, and everything else is
      cluster-bound service-account tokens not worth moving — which is why the
      index exists and why the count on its own means nothing. In the `openssf`
      cluster's `default` namespace: `github` (`app_id`, `app_key`,
      `installation_id`, `token`), `gitlab` (`auth_token`), and `fastly`
      (`purge_token`). The `criticality-score` cluster holds its own `github`
      of the same shape plus `enumerate-github-auth` and `github-staging`.
      **The GitHub App credential this task was written for is captured**, key
      material included. That part is done.
      Two things nobody had on a list:
      * **A GitLab token.** Scorecard scans GitLab, and that credential has to
        exist in the new environment too. It appears in no sync note, no
        action item, and nowhere else in this change.
      * **The Fastly purge token exists twice** — here, and in Secret Manager
        as `fastly_purge_token`, which is what the API reads. Two copies of one
        credential means a rotation that updates one and not the other leaves
        half the system purging with a dead token, silently, because a failed
        purge looks exactly like a cache that has not expired yet. Worth
        collapsing to one during the move rather than faithfully reproducing
        the duplication.
      **Still open on the follow-through, not the capture.** Decided
      2026-08-28: the destination is **AWS Secrets Manager in the new account**,
      co-located with what consumes them, which means an IAM policy and a naming
      scheme that do not exist yet — real work rather than a paste. Delete the
      capture directory once they land; it is a staging area with a shutdown
      clock, not a destination. Re-issue rather than transplant wherever the
      issuer makes that cheap.
      Three decisions on specific credentials:
      * **The GitLab token is required, not an inventory curiosity.** Scorecard
        scans GitLab, so if `auth_token` does not exist in the new environment
        that scanning stops — quietly, since nothing else reports it.
      * **Collapse the Fastly purge token to one secret**, rather than
        reproducing the Secret Manager/cluster duplication. Deliberately *not*
        lift-and-shift here: the duplication's failure mode is invisible, since
        a purge with a dead token is indistinguishable from a cache that has not
        expired, and it compounds 6.3a where purging is already the defect.
      * **`criticality-score`'s three credentials are out of scope and need an
        owner.** That cluster is a different OpenSSF hosted service dying on the
        same account. Flagged here so it is visible rather than assumed handled;
        nobody in the cutover thread has claimed it.
      **Credentials held outside the project are a re-issue task, not a capture
      task.** GitHub organization and repository Actions secrets cannot be read
      back through any API. If any of the App credentials live there, they have
      to be minted fresh in the new environment, and that wants deciding before
      the cutover window rather than inside it.
- [x] 6.1 **Superseded, not done.** 6.2a's decision to make AWS the staging
      origin replaced the Cloud-Run staging-tag shape this task assumed.
- [x] 6.2 **Superseded, not done.** Same decision as 6.1 — see 6.2a.
- [ ] 6.2a **Decided (2026-08-28): AWS becomes the staging origin first, and the
      staging flip *is* the rehearsal.** Rather than deploy a parallel
      non-production revision, stand the new infrastructure up on AWS and point
      the **Fastly staging service's** backend at it. `api-staging.scorecard.dev`
      and `api-staging.securityscorecards.dev` then exercise the AWS stack end
      to end, through the same CDN path production uses, before production's
      backend is touched. This supersedes 6.1/6.2's Cloud-Run shape, which
      assumed the destination was another GCP revision.
      Why it is better than what it replaces: the staging flip is the identical
      operation to the production flip — one backend field, same rollback — so
      the rehearsal and the event share a procedure rather than merely
      resembling each other.
      Three things it does not give for free, none blocking:
      * **Staging has no ESPv2 gateway and production does** (6.3c). So a clean
        staging run does not exercise the gateway layer. If production keeps the
        gateway after cutover, the rehearsal is missing a hop; if production
        drops it, then dropping it is a *second* variable changing at the same
        moment as the origin. Decide which before 6.4, not during it.
        **Decided (2026-08-29): dropped.** ESPv2/Cloud Endpoints is GCP-specific
        and has no AWS equivalent to carry forward — the migration leaves it
        behind along with the rest of GCP, not as a separate choice. `provision-
        aws` 9.4 also found a concrete reason to want it gone regardless: its
        stale 2023-08-30 contract rejects a valid CORS preflight the application
        answers correctly once the gateway isn't in front of it.
      * **Repointing staging spends the existing control.** `scorecard-api-
        staging` on GCP is currently what staging serves; once the backend
        moves, there is no longer a GCP staging to compare against. Capture
        whatever baseline is wanted from it first.
      * **The staging hostnames are edge-cached** with the same year-long
        `Surrogate-Control` as production. A test that does not purge or
        cache-bust measures the edge, not the new origin.
        **Closed (2026-08-29):** ran `conformance.sh` CDN-to-CDN
        (`api.scorecard.dev` vs `api-staging.scorecard.dev`, not the raw
        origins) rather than origin-to-origin, so this run exercises Fastly
        too. Confirmed first that this measured the new origin rather than a
        stale edge copy: `api-staging.scorecard.dev` came back `age: 0,
        x-cache: MISS` on every request, including every one that later showed
        a difference, so the comparison genuinely reached AWS through the CDN.
        Same 4 differences as `provision-aws` 9.4's origin-to-origin run,
        nothing new introduced by the CDN hop.
- [x] 6.2b **Gate (decided 2026-08-28): staging conformance on AWS. Satisfied 2026-08-29.** The
      production flip waits on `scripts/api-conformance/conformance.sh` running
      clean against the AWS-backed staging endpoint. Stephen calls it, and
      expects the criteria to move as the remaining steps land — so this is the
      standing gate, not a frozen checklist. 0.8's approvals are still
      unrecorded and are a separate question from this one.
      **Evidence:** provision-aws 9.4–9.7 (origin conformance, headers, object keys, IAM boundary verification), migrate-api 6.2a CDN-path run (staging edge-to-edge against production), task 7.3 (TLS chain to ACM issuer verified 2026-08-29 off-VPN). Staging origin live with real corpus, proven against production, AWS infrastructure verified end-to-end.
- [x] 6.3 Run the response diff against production (**W11**, step 3).
      **Harness built and exercised against production:**
      `scripts/api-conformance/` — 20 requests covering the two-bucket read
      fallback, absent and malformed input, path traversal, every documented
      badge style, and the CORS headers the website depends on. Compares status,
      body, and the cache headers; ignores per-deployment noise; records
      `age`/`x-cache` and prints them beside any body difference.
      Deliberately live-against-live rather than against a committed fixture:
      result bodies change on rescan, so a stored baseline is stale within a
      week and every later run drowns in false differences.
      **Calibrating it against the two production hostnames found a real
      defect** — see 6.3a. Run it against *origins*, not CDN hostnames.
      **Satisfied by provision-aws 9.4** (`conform-prod-00.log`):
      origin-to-origin, `FAIL: 4 of 20`, all four the known ESPv2 delta,
      already adjudicated. Same evidence 6.2b already cites.
- [x] 6.3a **Finding: the two published hostnames serve different data.**
      `api.scorecard.dev` and `api.securityscorecards.dev` front the same
      service, but returned results for `github.com/ossf/scorecard` from scans a
      week apart (`date` 2026-08-22 vs 2026-08-15) — same resolved commit, same
      engine version, both Fastly `HIT` at different ages. `Surrogate-Control`
      is `max-age=31557600`, so an edge object survives a year unless purged,
      and `post_results.go` purges a single `API_BASE_URL`. A purge refreshes one
      hostname and leaves the other stale.
      Two consequences. Operationally this is a **pre-existing production
      defect**, not something the migration introduces: which hostname a
      consumer uses determines how fresh their results are. For the migration it
      means the cutover diff must run origin-to-origin, or it measures cache
      vintage rather than behavior. Worth fixing at the purge rather than
      carrying across; not in this change's scope.
- [x] 6.3c **Finding: the cutover is a Fastly backend change, not a DNS
      repoint.** Both `api.scorecard.dev` and `api.securityscorecards.dev` are
      `CNAME`s to `x.sni.global.fastly.net` with a 300s TTL. Fastly is the front
      door for both; the origin is configured inside Fastly, and no Cloud Run
      domain mapping is in the request path — which is why two attempts to
      capture domain mappings were chasing something that does not exist.
      This change has described phase 6 as "repoint DNS" throughout, including
      in **W11**. That is wrong, and wrong in a way that matters:
      * **The control plane is Fastly**, which is the one system in the
        inventory that `gcloud` cannot reach and that nobody has captured yet.
        It is now the highest-value uncaptured item, not a footnote.
      * **Rollback is faster and safer than assumed** — flip the Fastly backend
        back, no DNS propagation to wait out. The 300s TTL bounds even a genuine
        DNS change, so neither direction is slow.
      * It also sharpens 6.3a: both hostnames resolve to the *same* Fastly
        service, cache separately (keyed by `Host`), and only one is purged.
      Task 6.4's wording and **W11** need correcting before the cutover is run
      from them. **Corrected in both.**
      Follow-on: `scripts/cutover/capture-fastly.sh` captures the Fastly side —
      backends (the origin, i.e. the thing the cutover changes), domains,
      conditions, VCL, snippets, cache settings. Needs a read-scoped
      `FASTLY_API_TOKEN`; the API's purge token is very likely purge-only and
      will 403. Verified only as far as a token-less environment allows: the
      bad-token path returns a real 401 from `api.fastly.com`, and it parses
      under bash 3.2, which is what macOS ships.
      **Rewritten to use the Fastly CLI and run clean against the real account
      (2026-08-25), 23 of 23 sections.** The request path is now fully known:

          api.scorecard.dev            ─┐
                                        ├─> Fastly "Scorecard Production API"
          api.securityscorecards.dev   ─┘     └─> backend "Host 1"
                                                  scorecard-endpoints-prod (ESPv2)
                                                    └─> scorecard-api-prod

      * **Both production hostnames map to one Fastly service.** That closes
        6.3a: one service, one backend, two hostnames, cached separately by
        `Host`, and `post_results.go` purges only `API_BASE_URL` — so the other
        hostname's objects sit until the year-long TTL expires.
      * **The cutover is one field**: backend `Host 1` on the production
        service. Rollback is restoring it. That is a much smaller and more
        reversible operation than "repoint DNS" implied. (Service IDs are
        account-scoped identifiers and stay out of this public repository —
        read them from the gitignored capture, `services.json`.)
      * **A complete staging path already exists** —
        `api-staging.scorecard.dev` and `api-staging.securityscorecards.dev` →
        Fastly "Scorecard Staging API" → `scorecard-api-staging` **directly,
        with no ESPv2 gateway in front**. So staging already demonstrates the
        gateway-less topology the AWS move is heading for, and W11 step 2 has a
        real end-to-end candidate URL rather than a bare Cloud Run address.
      * Production Fastly is on active version **1** and the API service runs as
        the default compute service account; staging is on version 9.
- [x] 6.3b **Finding: production is six months behind `main`, so the cutover is
      not purely a re-host.** The serving image is tagged with webapp commit
      `765e6ec` (2026-02-06). `main` has moved 25 commits since, 3 of them
      touching the API — and one, `f2e9814`, is a deliberate **behavior change to
      the publish path**: runner-label matching moves from a fixed allowlist to a
      regex, which newly *accepts* `ubuntu-26.04` and `-arm` variants and newly
      *rejects* `ubuntu-18.04` and `20.04`, and the rejection status changes from
      500 to 400.
      The behavior freeze preserved **upstream `main`, not what production
      runs**, and this change had not drawn that distinction. Consequences:
      W11's response diff cannot show POST-path equivalence, because the two are
      genuinely not equivalent; and any project still pinning an EOL Ubuntu
      runner will start failing to publish at cutover — a user-visible
      regression that lands at the same moment as the migration and will be
      attributed to it.
      The change itself is desirable (it fixes recurring publish failures in
      `ossf/scorecard-action`).
      **Decided (2026-08-25): ship the newer version.** Deploying a six-month-old
      commit to preserve an equivalence that would be broken days later is
      ceremony. Two obligations follow from choosing it, and they are the reason
      this is recorded rather than assumed:
      * **The cutover notice must say that EOL Ubuntu runners stop being
        accepted.** A project pinning `ubuntu-20.04` in its Scorecard workflow
        publishes today and will not after cutover. That regression arrives with
        the migration and will be attributed to it, so it is announced rather
        than discovered.
      * **W11's response diff cannot be read as proving POST-path equivalence.**
        It never could here; the two versions differ deliberately. The gate for
        that path is 6.6 — watching a real Action upload land — and it is worth
        watching one from a repository on a *supported* runner and, if one can be
        found, one on an EOL runner to confirm the rejection is the clean 400
        rather than a 500.
- [ ] 6.3d **Decided (2026-08-28): the nameserver move is a second switch, and
      it does not run with the cutover.** 6.3c established that the cutover is
      one Fastly backend field. Separately, the zones themselves are hosted in
      **Cloud DNS**, which is a GCP service and therefore dies with the account.
      Both are true, they were being scheduled into the same window, and they
      have opposite reversibility:
      * **The Fastly flip rolls back in seconds** — restore the backend, no
        propagation, no third party.
      * **A delegation change rolls back on the registry's timetable.** It is a
        parent-zone change made through the registrar, so backing it out is not
        ours to schedule. 6.3c's "rollback is faster than assumed" finding
        covers the backend flip and must not be read as covering this.
      So the API cutover proceeds with **no DNS change at all** — both hostnames
      keep resolving to Fastly exactly as they do today — and the delegation
      move is sequenced against the account shutdown, which is its actual
      deadline, rather than against the cutover, which is not.
      What the delegation move needs, none of it blocking the cutover:
      * **The zones are small enough to port by hand: 17 records across two
        zones**, both captured (`dns-records-scorecard.json`,
        `dns-records-scorecard-existing.json`). That capture is the rebuild
        source; there is no export step still owed.
      * **The four `_acme-challenge` CNAMEs to `*.fastly-validations.com` are
        the ones that fail silently.** One per API hostname, prod and staging.
        Drop them and nothing breaks at cutover — Fastly TLS renewal breaks
        weeks later, long after anyone would connect it to the migration. They
        are the records most likely to be missed precisely because nothing
        immediately depends on them.
      * **The website is already on Netlify** and is not part of this: both
        apexes are `A 75.2.60.5` and both `www` are CNAMEs to
        `ossf-scorecard.netlify.app`. Only zone *hosting* is in GCP.
      * Access is not ours today. The domains are LF-registered and the
        delegation is changed through LF IT (ticket **IT-30079**), so the lead
        time is a third party's, which is the other reason not to couple it to
        a cutover window.
      * The registrar also holds `scorecards.dev`, `openssfscorecard.dev`, and
        `openssfscorecards.dev`, which were not on this change's inventory. The
        last two are said to redirect to `securityscorecards.dev`. Confirm what
        serves them before assuming the two captured zones are the whole story.
      **`nsone.net` *is* Netlify DNS.** Netlify's managed DNS runs on NS1
      infrastructure, so `dns*.pNN.nsone.net` is what IT-30079 asked for and
      what it got. Recorded because the opposite was briefly concluded from the
      hostname alone: an unfamiliar provider name in a delegation is not
      evidence that the wrong provider was used, and reading it that way
      manufactured a website outage that was never there.
      **Each zone gets its own nameserver pool, and they differ.**
      `scorecard.dev` is delegated to the **p01** set and
      `securityscorecards.dev` to the **p09** set. A checker with one
      `NEW_NS` therefore asks a server that is not authoritative for the other
      zone and gets nothing back — which, in a tool that treats an empty answer
      as a dropped record, is a false failure across every record of the second
      zone. The per-zone mapping is not a detail; it is the difference between
      the second zone reading as catastrophic and reading as fine.
      **Delegation was changed on 2026-08-28**, propagating over a few hours to
      24. Every check below is now post-delegation verification rather than a
      pre-flight gate, and 6.3c's "flip the Fastly backend back" remains the
      only fast rollback in the system.
      **First diff against the new nameservers (2026-08-28) covered one domain
      of two.** Seven mismatches were reported on `scorecard.dev`. Two of the
      three underlying facts are not findings:
      * **The apex and `www` addresses are most likely Netlify's own.** They
        move off `75.2.60.5` — the single apex address Netlify documents for
        *external* DNS — to a pair of addresses served by Netlify DNS itself,
        and `www` moves from a CNAME to those same two, which is what ALIAS
        flattening looks like. So this is probably correct-by-construction
        rather than broken. **Verify it by fetching the site, not by diffing
        records**: a record comparison across a provider change cannot
        distinguish "reconfigured" from "equivalent", and this one was read as
        the former on no evidence.
      * **`NS` is not a discrepancy; it is the migration.** Old and new
        nameservers must disagree about NS during a delegation move. Counting
        it as a mismatch inflates the total and teaches people to skim.
      * **`www` was one difference reported five times.** An authoritative
        server returns the CNAME for any query type, so A/AAAA/TXT/NS at a
        CNAME name all echo the CNAME rather than revealing four more records.
      * **Every `api.*` and `api-staging.*` record matched** — the result the
        decoupling above predicts. The API rides a CNAME to Fastly and is
        indifferent to which nameserver serves it, so the delegation move
        touches the website and leaves the API alone.
      **The second run verified nothing either, and claimed the opposite.**
      Re-run after the per-zone fix, it reported 13 mismatches whose "new"
      values were fragments of `dig`'s own error text. `dig +short` writes
      "no servers could be reached" to *stdout*, so redirecting stderr does not
      suppress it, and piping it into the comparison turns an unreachable
      resolver into thirteen content differences. Fixed by checking the exit
      status, dropping `;` lines, and classifying an unanswered query as
      `[UNREACHABLE]` with its own exit code: a run that could not ask is not a
      run that found nothing. A preflight reports that once rather than once
      per record.
      **`securityscorecards.dev` went unverified for the first two runs**: 6 of
      the 15 records, including `api.securityscorecards.dev`, the hostname 6.3a
      already flags as serving staler data than its sibling. The first diff
      queried `securityscorecard.dev` — singular, not a zone — so every lookup
      returned empty from both nameservers, and a skip-when-neither-has-a-record
      guard reported that silence as a clean section with no rows. Corrected by
      deriving the check list from the capture's `dns-records-*.json` instead of
      a hand-written list: a name can now only be missed by being absent from
      the capture, and an empty answer where the capture has a record is a hard
      failure rather than a skipped row.
      **Third run (2026-08-28), off the VPN, is the valid one — and the API
      side is clean.** All eight `api.*` and `api-staging.*` CNAMEs to Fastly
      matched on **both** zones, as did all four `_acme-challenge` CNAMEs and
      the apex `TXT`. The `NS` rows confirmed the p01/p09 split. Nothing the
      cutover depends on was disturbed by the delegation, and the TLS-renewal
      records flagged above as the silent-failure class came through intact.
      **Its four remaining rows were three checker artifacts and one real
      outage** (6.3e). The apex `A` "mismatch" on both zones is ALIAS
      flattening: the answer varies between queries — a run an hour earlier
      returned a different pair, in a different AWS region — so comparing it
      against the single captured address can never clear, and `75.2.60.5` is
      the address Netlify documents for zones hosted *elsewhere*.
      `www.scorecard.dev` reported `[MISSING]` only because the check queries
      the record *type* the capture held; CNAME became ALIAS, and the name
      serves a 301 to the apex.
      **The lesson is that record comparison cannot verify a name that
      terminates TLS.** The two `www` rows were byte-identical at the record
      layer — same captured CNAME, same absence, same verdict — and one of them
      was down. A classifier that resolved `A`/`AAAA` and called the type change
      benign, which is what was about to be built, would have marked both fine
      and buried a live outage. Fetching the names is the check; the record diff
      is only sound for `api.*` and `_acme-challenge`, where it is exactly right
      and where it just came back clean.
      **Still uncovered by anything we have:** records present in the *new* zone
      but absent from the capture. The two new apex addresses are exactly that
      class, and they surfaced only because the apex happened to appear on the
      old hand-written list. Enumerating them needs a zone export from the
      new provider; a diff driven by the old zone can prove nothing was dropped,
      never that nothing was added.
- [x] 6.3e **`https://www.securityscorecards.dev` is serving a certificate that
      does not cover it**, found by fetching the four web hostnames after the
      delegation. TLS negotiates far enough to present a certificate, so the
      name resolves and Netlify answers; the SAN list simply omits it. The apex
      returns 200, so the certificate covers `securityscorecards.dev` and not
      its `www`. `scorecard.dev` shows the intended shape: apex 200, `www` 301
      to the apex, one certificate spanning both.
      Fix is a Netlify site setting — add `www.securityscorecards.dev` as a
      domain alias and the certificate provisions itself. Not a DNS change, and
      not something the record diff could ever have surfaced.
      **Determined (2026-08-28): pre-existing, so it stays out of the cutover
      notice.** No certificate ever covered the name; the delegation did not
      break it and the notice must not imply otherwise. Fix it as ordinary
      maintenance. The distinction was worth spending a query on rather than
      assuming either way — announcing a self-inflicted regression that was not
      one costs credibility exactly when the migration needs it.
- [ ] 6.3f **Give `dnsdiff.sh` an HTTPS probe for web-facing names.** Record
      comparison is sound for `api.*` and `_acme-challenge` and unsound for
      anything terminating TLS, per the reasoning in 6.3d. 6.3e is a working
      example of a name the record layer called identical to a healthy one.
      Explicitly *not* the `[TYPE CHANGED]` classifier that was drafted first:
      resolving `A`/`AAAA` to excuse an absent CNAME would have marked the
      broken hostname benign.
- [x] 6.3g **Re-ran `capture-fastly.sh` (2026-08-28); the earlier output had
      been lost.** The 2026-08-25 capture was not on disk and, being gitignored,
      was not recoverable from the repository either — while 6.3c cites its
      `services.json` as where the service identifiers live and treats it as the
      rollback source for backend `Host 1`. Redone clean, 23 of 23 sections.
      Two things it settles:
      * **The rollback target is unchanged.** Production's `Host 1` still points
        at the `scorecard-endpoints-prod` Cloud Run URL, matching the request
        path in 6.3c. The one field the cutover changes is captured again.
      * **The account has a third service, and it is nothing.** "Unnamed
        Service", created 2026-05-15, has no domains, no backends, one version,
        and was never activated. It cannot carry traffic. Recorded only so the
        next reader of `services.json` does not have to re-derive that — 6.3c's
        two-service topology was never wrong.
      One incidental confirmation for 6.3a: Fastly's own domain descriptions
      call `api.scorecard.dev` "the production API domain" and
      `api.securityscorecards.dev` "the old domain". So the single purge that
      `post_results.go` issues covers the *canonical* hostname and strands the
      legacy one, which is the less bad way round for that defect to fall.
- [ ] 6.4 Shift traffic and register `ossf/scorecard-infra` in OSS-Fuzz.
      **Requirement (decided 2026-08-28): the new backend is a hostname that
      terminates TLS with a certificate Fastly can verify** — not a bare EC2
      address. Today's backend is the Endpoints gateway's Cloud Run hostname,
      which gives origin TLS verification and SNI for nothing. Pointing at an IP
      instead means setting SNI and `override_host` by hand and either finding a
      certificate valid for an IP or disabling origin verification, which is a
      security-posture change riding along inside a migration whose whole claim
      is that behavior did not change. Keeping it a hostname also keeps the flip
      a one-field edit in both directions.
      **Traffic shift: done** — measured this session at 100% on both
      hostnames, GCP backend fully removed.
      **Cloud Build trigger: no action needed.** Image builds already moved to
      GitHub Actions (4.10, `publish-api-image.yml`); the old trigger has
      nothing left to repoint and dies with the GCP project on 2026-08-31.
      **OSS-Fuzz: not a repoint.** `ossf/scorecard-webapp`'s existing
      `scorecard-web` OSS-Fuzz project stays with the website, which is not
      moving. The API's fuzz harnesses (`cifuzz.yml`, removed from
      `scorecard-webapp` at 7.3) move to `ossf/scorecard-infra`, so the real
      action is **registering `ossf/scorecard-infra` as a new, separate
      OSS-Fuzz project** — not done yet. Auditing every Scorecard subproject's
      OSS-Fuzz configuration is a related, explicitly non-blocking follow-up,
      outside this task.
- [x] 6.5 **Done 2026-08-30.**
      [`ossf/scorecard#5208`](https://github.com/ossf/scorecard/issues/5208).
- [x] 6.6 **Satisfied 2026-08-30.** Two publishes run against
      `justaugustus/scorecard-action-test`: the first proved the POST→S3 write
      path; the second, against a URL already holding a real cached entry
      (`age: 67`, `max-age=600`), proved the Fastly purge fires from the
      AWS-backed environment — the cached copy was fully invalidated (`age: 0`,
      `x-cache: MISS, MISS, MISS`) and replaced within seconds of the publish.
- [ ] 6.7 Hold for the agreed period, watching error rates and the badge path.
      **Rollback:** available only until 2026-08-31 — shift traffic back to the
      captured prior revision (the code still exists upstream, so no code
      restoration is needed), and the GCP backend has already been fully
      removed once, so this would mean re-adding it. After 2026-08-31, GCP
      access ends and this path is gone; recovery is forward-only — redeploy a
      known-good image by digest, or restore from S3.

## 7. Removal from ossf/scorecard-webapp

- [ ] 7.1 Notify the Scorecard community again before removal.
- [ ] 7.2 Delete `app/`, `main.go`, `openapi.yaml`, `Makefile`,
      `Makefile.swagger`, `COPYRIGHT.txt`, `Dockerfile`, `go.mod`, and `go.sum`.
- [ ] 7.3 Remove the Go CI: `main.yml`, `cifuzz.yml`, the Go half of the CodeQL
      matrix, and the gomod and docker Dependabot entries.
- [ ] 7.4 Trim `docs/dns.md` to the site half (**W6**).
- [ ] 7.5 Rewrite `README.md` to describe a website-only repository, with a
      pointer to the API's new home.
- [ ] 7.6 Update `.github/CODEOWNERS` and any issue or PR templates that route
      API reports to the wrong repository.
- [ ] 7.7 Confirm the site still builds and deploys, and that its viewer still
      resolves against the API.
- [ ] 7.8 Confirm nothing in the remaining tree references the removed paths.
- [ ] 7.9 **Do not delete `ossf/scorecard-webapp`'s release tags.** Deleting the
      code is safe; deleting `v1.0.5` is what breaks `jetstack/tally`, the one
      external consumer (0.1, **W12**). This change strips those same tags from
      the *import* (**W2**) — the operations look alike and have opposite
      consequences, so state the distinction in the removal pull request rather
      than trusting it to be obvious.
- [ ] 7.10 Verify the obligation holds rather than assuming it: after removal,
      confirm `go mod download github.com/ossf/scorecard-webapp@v1.0.5` still
      resolves.

## 8. Change closeout

- [ ] 8.1 `openspec validate migrate-api --strict` passes.
- [ ] 8.2 Verify every success criterion in the proposal and design is met.
- [ ] 8.3 Archive the change once implemented and merged.
