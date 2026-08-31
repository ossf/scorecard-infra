# Proposal: Provision the AWS batch scanning plane in OpenTofu

## Why

The `openssf` GCP project was turned down 2026-08-31, and cron stopped the day
before. The public corpus is frozen at the last completed cycle
(2026-08-24 02:00 UTC) and is served from a year-long Fastly
`Surrogate-Control`, accepted as a short-window staleness tradeoff. Closing
that window means the batch pipeline has to run somewhere, and there is no
GCP left to run it on.

`migrate-batch-pipeline` grafted `cron/` into this repository with full
history, but its own group 6 — the GCP production cutover — closed out void:
every element its phase ordering depended on (Cloud Build triggers, the
PubSub → GCS → BigQuery cycle, the rollback target) lived in the `openssf`
project and does not survive its turndown. That change's proposal also says,
in its own words, *"This is a repository split, not a rewrite. No cron
behavior changes."* Standing up new compute, a new queue, and a new scheduler
is not that; it needs its own change, the way `provision-aws` was `migrate-api`'s
sibling rather than an amendment to it.

What has changed since `provision-aws`: the serving plane now runs on AWS,
`configure-result-buckets` is closed, and the `cron/` equivalence freeze
lifted 2026-08-30 with a snapshot recorded in `cron/initial-graft.md`. Nothing
upstream of this change is still blocking it.

## What Changes

- **Add `deploy/cron/production/`**, a flat root module — matching the
  precedent `deploy/cron/secrets` already set, not `deploy/api`'s nested
  `environments/{staging,production}/` split, which exists there because
  staging and production need materially different bucket access (staging is
  read-only). No such split exists for the batch plane yet. Composed with two
  new modules (`deploy/cron/modules/cluster`, `deploy/cron/modules/queue`) and
  the already-landed `deploy/cron/secrets`.
- **Run the batch pipeline on EKS**, deliberately not the serving plane's ECS.
  The two planes were split onto separate clusters on purpose: so the two
  migrations can proceed independently under a one-person time budget, and so
  neither workload contends with the other for capacity on a shared cluster.
  EKS also lets `cron/k8s/*.yaml` — already CronJob/Deployment/RBAC-shaped —
  port with minimal rewriting, which is what makes a single-maintainer
  migration tractable at all.
- **Share `deploy/api`'s VPC and NAT Gateway; provision no second one.** A
  dedicated VPC's NAT Gateway costs roughly $32-35/month plus data processing,
  on top of the ~$110-145/month already budgeted for serving, for isolation
  the cluster split already provides at the compute layer. The batch cluster
  gets its own private subnets and route tables inside the existing VPC.
- **Replace Pub/Sub with SQS Standard + a DLQ.** The harder part is not the
  queue itself: the current GCP subscriber extends its ack deadline to 600s
  with a renewing heartbeat, and plain SQS `ReceiveMessage` has no equivalent.
  A `ChangeMessageVisibility` heartbeat is the load-bearing code change this
  proposal depends on; without it, a still-running scan becomes visible again
  and gets double-worked.
- **Adopt the six existing corpus buckets as data sources; create three new
  ones for testing.** `provision-aws`'s 2026-08-29 account capture already
  found `ossf-scorecard-results`, `ossf-scorecard-cron-results`,
  `ossf-scorecard-data2`, `ossf-scorecard-rawdata`,
  `ossf-scorecard-input-projects`, and `ossf-scorecard-cii-data` present in
  AWS via DataSync replication from GCS. None of the six is declared as a
  resource, for the same reason `provision-aws`'s **A13** gives for the two it
  adopted. Three of the six are written by a normal scan cycle
  (`data2`, `cron-results`, `rawdata`); `cron-results` is also the exact
  bucket `deploy/api` reads as `SCORECARD_CRON_RESULTS_BUCKET_URL`, the live
  API's fallback for every repository without a self-published result. Test
  runs get their own counterparts to those three so a canary cannot surface
  in a real `api.scorecard.dev` response or corrupt the corpus.
- **Investigate the pre-existing `openssf-scorecard` SQS queue before
  deciding whether to adopt or replace it.** `provision-aws`'s capture found
  one SQS queue already in the account, noted only as belonging to the batch
  plane. Its name does not match `cron/config/config.yaml`'s topic name.
- **Deploy workloads as Kubernetes manifests, not Terraform resources.**
  OpenTofu provisions the AWS-side resources (cluster, node groups, Pod
  Identity role mappings, the queue, bucket access); a GitHub Actions
  workflow applies `cron/k8s/{controller,worker,cii,auth}.yaml` via `kubectl`
  after `aws eks update-kubeconfig`. Converting the manifests into
  `kubernetes_manifest` Terraform resources would discard the "ports nearly
  as-is" property EKS was chosen for, for no benefit.

### Explicitly out of scope

- **The BigQuery transfer** (`transfer.yaml`, `transfer-raw.yaml`). Already
  decided as its own later change: the public dataset is a consumer surface
  whose retirement needs its own community notice, and the raw JSON in S3
  makes the history rebuildable regardless.
- **The release-test tier** (`controller.release.yaml`, `worker.release.yaml`,
  `transfer.release.yaml`, `transfer.release-raw.yaml`,
  `webhook.release.yaml`). Whether that environment still runs at all is
  unconfirmed, and `webhook.release.yaml` already names an image nothing in
  this repository builds — a known anomaly recorded in
  `migrate-batch-pipeline` 4.4a. Porting four more workloads on an unconfirmed
  premise is not worth doing up front.
- **`:stable` tag promotion.** Unresolved since before the serving cutover
  (`migrate-batch-pipeline` 4.4) and orthogonal to standing up AWS compute —
  images publish to `ghcr.io` regardless of what promotes one to `:stable`.
- **Removing `cron/` from `ossf/scorecard`.** That is `migrate-batch-pipeline`
  group 7, gated on its own community notice, and has nothing to do with
  where the AWS compute runs.
- **A run-catalog / correctness rework** (explicit repository outcomes,
  conditional `latest` publication, idempotent finalization). Known
  correctness debt in the GCP implementation, inherited as-is. Fixing it
  belongs to a change that isn't also standing up new compute for the first
  time.

## Capabilities

- **aws-batch** (new) — the batch plane's AWS deployment: EKS, the queue, Pod
  Identity, and the corpus bucket contract, mirroring what `aws-serving`
  states for the serving plane.

`infrastructure-as-code` already covers environment isolation,
discovery-before-apply, secret provisioning, and locking generically — no
batch-specific extension needed there.

## Impact

- **Affected code:** new `deploy/cron/production/`,
  `deploy/cron/modules/{cluster,queue}/`; `cron/internal/pubsub/` gains an SQS
  subscriber and a URL-scheme-based selector; `cron/data/blob.go` links
  `gocloud.dev/blob/s3blob`; a new GitHub Actions workflow builds on the
  existing `publish-cron-images.yml` to deploy by digest. No change to
  `api/`, `internal/`, or `cmd/`.
- **Affected specs:** adds `aws-batch`.
- **Reversible by construction.** No production schedule points at this
  compute until the verification gate (canary + a killed-worker redelivery
  test) passes against the three test buckets. The failure mode of abandoning
  this change is unused AWS resources, same as `provision-aws`.
- **Cost, approximate:** EKS control plane ($0.10/hour, ~$73/month) plus a
  worker node group sized to the current 14-worker baseline and a small
  system pool. No new NAT Gateway (shared with `deploy/api`'s). To be
  confirmed against real numbers once sized.

## Open questions carried into implementation

1. **Whether the release-test environment still exists at all.** Establishing
   this is a prerequisite to porting the release-test tier, not this change's
   job to answer.
2. ~~**What the `openssf-scorecard` SQS queue actually is.**~~ Answered by
   task group 1 on 2026-08-31: a tuned but never-used placeholder, created
   2026-08-26 and carrying no message on any day since. Not adopted; see
   **E8**.
3. **Node group sizing beyond the 14-worker baseline.** Tune after
   verification, not before — the same discipline `provision-aws`'s **A8**
   applied to ECS task count.
