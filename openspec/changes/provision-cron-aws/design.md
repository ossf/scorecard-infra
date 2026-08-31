# Design: the AWS batch scanning plane

Decision tags **E1**-**E9**. They are referenced from `tasks.md` and should be
cited in commit bodies, following the convention the other changes use.
(A/B/C/D/F/FF/W are taken by `provision-aws`, `configure-result-buckets`,
`migrate-batch-pipeline`, the original hybrid-server design,
`add-feature-flagging`, `add-upstream-fallback`, and `migrate-api`
respectively.)

## What the account already contains

Captured fresh 2026-08-31 (task group 1) with `scripts/cutover/capture-aws.sh`
and a new sibling, `scripts/cutover/capture-aws-batch.sh`. The sibling exists
because four of group 1's questions have no section in the first script: it
never calls DataSync, `sqs list-queues` returns a URL and nothing else, no AWS
API reports "a consumer exists" (that is a CloudWatch question), and route
tables — which **E5**'s shared-VPC plan turns on — are not captured at all.

An earlier draft of this section inherited `provision-aws`'s 2026-08-29
capture and proposed that group 1 merely confirm nothing had changed. That
was the wrong bar, and re-running found why: `provision-aws` itself landed in
between, so the account has legitimately moved, and three of the facts below
are not what the inherited capture would have implied.

**All six corpus buckets exist** in `us-east-1`, under their GCS names:
`ossf-scorecard-results`, `ossf-scorecard-cron-results`,
`ossf-scorecard-data2`, `ossf-scorecard-rawdata`,
`ossf-scorecard-input-projects`, `ossf-scorecard-cii-data`. `provision-aws`
adopted the first two; this change adopts the rest. All six share one shape:
**versioning off**, no lifecycle configuration, no bucket policy, with
encryption and a public-access block present. That confirms **E7**'s premise
rather than assuming it. The **E9** state bucket, `ossf-scorecard-tfstate`,
has versioning, lifecycle rules and a policy.

**The corpus is frozen exactly where the proposal says it is.** The newest
date partition in both `data2` and `rawdata` is `2026.08.24/`, on a visible
weekly cadence — matching the last completed cycle, with nothing written
since.

**DataSync replication is still running, and degrading.** Twenty tasks exist
in three generations: an original GCS → `aboutcode-scorecard/<prefix>` set, a
`*-local-s3-to-s3` set that fanned those prefixes out into the per-bucket
buckets, and the six `*-direct-to-s3` tasks that supersede both. Only the last
set is scheduled. Two of those six are not healthy: `results` has had its
schedule **disabled** since 2026-08-29, deliberately, hours after the serving
plane went live — replicating stale GCS content over the bucket the live API
writes to would clobber it. `cron-results` moves ~787k files per run on an
hourly schedule it cannot finish inside, so each run collides with the
previous one and errors `FailedToLaunchScheduledTask`. Neither blocks this
change; both are recorded because "still being written by DataSync" turned out
to be three different answers depending on the bucket.

**The pre-existing `openssf-scorecard` SQS queue has never carried a
message.** See **E8**, which this capture resolves rather than leaves open.

**`deploy/api` built two VPCs, not one** — `scorecard-api-staging`
(`10.20.0.0/16`) and `scorecard-api-production` (`10.21.0.0/16`), each with
its own NAT Gateway and its own S3 gateway endpoint. **E5** is written as
though there were one; the batch plane shares the production VPC.

**Three of five Elastic IPs are free.** `describe-addresses` returns six
against a quota of 5 that has never been raised, which looks like a breach and
is not: four are `RequesterManaged: true` under `amazon-elb`, sitting on the
two load balancers' interfaces, and service-managed addresses do not count
against `L-0263D0A3`. Only the two NAT Gateway EIPs are self-allocated, which
`deploy/`'s single `aws_eip` declaration corroborates. Stated precisely
because the six-against-five reading briefly turned into a capacity argument
for **E5** during this very capture, and **E5** has no capacity argument — it
is cost-driven, and that is enough.

**No EKS cluster, no application IAM roles for the batch plane, and no SQS
consumer exist.** Zero EKS clusters and zero Lambda event source mappings.
None of the account's 29 IAM roles is a batch-plane application role: 8
service-linked, 8 Application Migration, 7 `AWSDataSyncS3BucketAccess-*`, and
the 6 serving-plane roles `provision-aws` created on 2026-08-29. The only
application secrets remain `deploy/cron/secrets`'s
`scorecard/cron/{github,gitlab}`.

## Compute

**E1 — EKS, one cluster, two node groups.** Chosen over the serving plane's
ECS deliberately, not by default. Two reasons, both from you rather than
inferred: the two planes were split onto separate clusters so the serving and
batch migrations could proceed independently — you are the only one with
sustained bandwidth for this work, and coupling the two migrations' compute
would mean neither could move without the other — and so batch workloads
never contend with the serving tier for capacity on a shared cluster.
Secondarily, `cron/k8s/*.yaml` is already CronJob/Deployment/RBAC-shaped, so
EKS is the lower-rewrite landing zone; under a one-person time budget that is
not a minor consideration.

Two node groups, not one: a small system pool for the controller (a
once-a-week CronJob) and the GitHub token-pool server (a small, always-on
Deployment), and a separate worker pool sized to today's GKE baseline of 14
workers. Matches `provision-aws`'s **A8** pattern — start at the known
baseline, tune after verification, not autoscaling from day one.

## Queue

**E2 — SQS Standard + a DLQ replaces Pub/Sub.** Uncontested; the fan-out
shape (one controller publishing shards, many workers consuming) has no
serious competing AWS primitive.

**E3 — the visibility-heartbeat rework is the load-bearing code change, and
comes before anything else in `cron/internal/pubsub/`.**
`cron/internal/pubsub/subscriber_gcs.go` extends its ack deadline to 600
seconds and renews it before expiry — a scan can run long, and without that
extension a still-running scan becomes visible again and gets picked up by a
second worker. Plain SQS `ReceiveMessage` does not do this. The new
`subscriber_sqs.go` has to implement it explicitly: receive with long
polling, establish a visibility timeout, run a heartbeat that calls
`ChangeMessageVisibility` before it expires, stop the heartbeat on ack/nack/
shutdown/cancellation, and configure a DLQ with a finite max receive count.
SQS is at-least-once even with the heartbeat, so output writes stay
idempotent regardless. **No full-corpus run is scheduled until this is
proven** under a deliberately slow scan with a worker killed mid-run: the
message should stay invisible while healthy, become available after the
kill, complete on retry, and leave no inconsistent output.

Subscriber selection becomes URL-scheme-based
(`gcppubsub://` vs `awssqs://`) rather than the current always-GCP-unless-
emulated default, so the same binary can run against either backend during
the transition.

**E8 — the pre-existing `openssf-scorecard` queue is a tuned but unwired
placeholder, and is not adopted.** Resolved by task group 1 rather than
assumed. Three candidate explanations went in — leftover from an abandoned
attempt, placeholder awaiting wiring, or already correctly shaped and merely
undocumented — and the capture settles it as the second:

| | |
|---|---|
| Created | 2026-08-26 21:36Z, account **root**, via the console |
| Tuned | 2026-08-28 14:04Z — `VisibilityTimeout` 30→3600, `ReceiveMessageWaitTimeSeconds` 0→20 (re-saved identically nine minutes later) |
| Throughput | 0 sent, 0 received, 0 deleted — **every day since creation** |
| Missing | no redrive policy, no tags, SSE off |

Not a leftover: it postdates the start of this migration. Not correctly
shaped: `RedrivePolicy` was submitted empty on all three calls, so no DLQ was
ever intended, and **E2** requires one.

**It is not adopted.** **E6**'s adopt-don't-create rule exists to keep
OpenTofu from being one deleted block away from destroying the corpus; a queue
holds no data and this one is provably empty, so that reasoning does not reach
it. What adoption would actually cost is importing a hand-made resource whose
policy, tags and redrive policy all get rewritten on the first apply — nearly
every attribute — under a name matching neither `cron/config/config.yaml`'s
topic (`scorecard-batch-requests`) nor its subscription
(`scorecard-batch-worker`).

What is worth keeping is the tuning, not the queue. Whoever set those two
values understood the workload: a long visibility timeout because a scan can
run long, and maximum long polling because workers poll continuously. Both
carry into the new queue as **E3**'s starting values rather than being
rediscovered. The existing queue is left in place — deleting someone else's
resource is not this change's call — and recorded here as unmanaged.

## Storage

**E6 — the six existing corpus buckets are adopted, not created.** Same
reasoning as `provision-aws`'s **A13**: they already exist and hold live,
DataSync-replicated data, so OpenTofu references them as data sources and
grants IAM access. Declaring them as managed resources would put the corpus
one `-target` mistake or one deleted block away from deletion, and OpenTofu
cannot distinguish "this should not exist" from "someone removed the block
that declared it."

**E7 — three new buckets, genuinely created, for testing without touching
production data.** Cross-referencing `cron/config/config.yaml` against the
six adopted buckets: a normal scan cycle writes to exactly three —
`result-data-bucket-url` (`data2`, shard/completion state),
`api-results-bucket-url` (`cron-results`), and `raw-result-data-bucket-url`
(`rawdata`). `input-projects` is read-only from the controller's side and
`cii-data` is written only by the separate, lower-frequency CII cronjob, so
neither gets a test counterpart yet.

`cron-results` is the most dangerous of the three to test against directly:
it is the *same bucket* `deploy/api` reads as `SCORECARD_CRON_RESULTS_BUCKET_URL`,
the live API's fallback for every repository without a self-published
result. A test write there can surface in a real `api.scorecard.dev`
response — not a corpus-integrity problem, a live-serving-correctness one.

Proposed names, to confirm during scaffolding: `ossf-scorecard-cron-results-test`,
`ossf-scorecard-data2-test`, `ossf-scorecard-rawdata-test` — the production
names with a `-test` suffix, so a bucket list is self-explanatory without a
lookup table. These three *are* declared as OpenTofu resources; **E6**'s
"don't declare what you didn't create" reasoning does not apply to buckets
this change creates.

They also get versioning, which the six adopted buckets do not have — the
2026-08-31 capture confirms versioning is off on all six rather than leaving
it assumed. Turning it on for the adopted buckets is out of scope (**E6**
keeps this change out of their configuration entirely), but there is no reason
to reproduce the gap in a bucket created fresh, least of all one whose purpose
is catching a bad write before it reaches production.

## Network

**E5 — shares the `scorecard-api-production` VPC and its NAT Gateway; no
second one is provisioned.** Cost-driven, and cost-driven only: a dedicated
VPC's NAT Gateway runs roughly $32-35/month plus data processing, on top of
the ~$110-145/month already budgeted for the serving plane in
`provision-aws`, for isolation the cluster split (**E1**) already provides at
the compute layer. There is no capacity argument alongside it — three of five
Elastic IPs are free, so a second NAT Gateway is affordable in quota terms and
simply not worth its price.

**Which VPC, specifically.** `deploy/api` built two — `scorecard-api-staging`
(`10.20.0.0/16`) and `scorecard-api-production` (`10.21.0.0/16`) — and earlier
drafts of this decision said "`deploy/api`'s VPC" as though that were
unambiguous. The batch plane shares **production**, `10.21.0.0/16`, whose four
existing `/20` subnets are `10.21.0.0` and `10.21.16.0` (public), `10.21.128.0`
and `10.21.144.0` (private). `10.21.160.0/20` and `10.21.176.0/20` extend the
private range for the batch cluster without colliding. Subnets-per-VPC and
route-tables-per-VPC are both 200; neither constrains this.

**The S3 gateway endpoint is the real coupling, and it is sharper than a
shared NAT Gateway.** Production already has one, `vpce-0cc8a7b4c119bfabd`,
associated with exactly the two existing private route tables. A gateway
endpoint is per-VPC per-service, so the batch cluster cannot stand up its own
alongside it: the batch route tables have to be added to that endpoint's
associations. Task 3.1 therefore decided more than it appeared to.

**Resolved (task 3.1): `deploy/cron/production` reads `deploy/api/production`'s
state via `terraform_remote_state` for VPC context (`vpc_id`, existing subnet
CIDRs, the endpoint ID) — read-only, one direction, no new coupling beyond
what is read. The endpoint's associations are split off the `aws_vpc_endpoint`
resource itself and onto the AWS provider's dedicated
`aws_vpc_endpoint_route_table_association` resource**, precisely because that
resource exists to let two Terraform roots each own association rows against
the same endpoint without fighting over an authoritative list — unlike
`aws_vpc_endpoint.route_table_ids`, which is a full-replacement attribute: any
root declaring it would silently remove associations it didn't create on its
next apply. `deploy/api/modules/network` gets a one-time edit — stop setting
`route_table_ids` inline on `aws_vpc_endpoint.s3`, declare
`aws_vpc_endpoint_route_table_association` for its own two existing private
route tables instead (additive at the AWS API level; the associations
themselves don't change) — and `deploy/cron/production` then declares its own
association resources against the same endpoint ID for its own route tables.
After that one edit, cron's route tables can change freely with no further
edits to `deploy/api` ever again.

This was chosen over the earlier draft here — an `additional_route_table_ids`
input on `deploy/api/modules/network`, with `deploy/api/production` passing in
cron's route table IDs — because that draft made every future change to
cron's route tables require a follow-up apply of the serving plane's root.
The association-resource split pays a one-time cost (the module edit) instead
of a recurring one.

Accepted tradeoffs, stated rather than hidden: the one-time edit to
`deploy/api/modules/network` still touches a serving-plane module before any
batch-plane code exists, reintroducing a sliver of the cross-change
coordination the cluster split was meant to avoid — smaller than the
recurring-apply draft, but not zero. It changes how `deploy/api/production`
manages the endpoint's *existing* two associations (verify with a full
`tofu plan`, no `-target`, before applying — this touches live serving-plane
state) without changing their runtime effect. A NAT Gateway outage, or a
connection-tracking limit hit during simultaneous heavy egress from both
planes, would be a shared-fate event; note that production runs a **single**
NAT Gateway serving both AZs today, so the batch plane inherits that single
point of failure rather than introducing it. None of this outweighs the cost
of a second NAT Gateway. Revisit if any of it causes real friction — this is
reversible, not structural.

## Workload deployment

**E4 — Kubernetes manifests, not Terraform resources.** OpenTofu's job here
stops at the AWS-side resources: the cluster, the node groups, Pod Identity
role-to-service-account mappings, the queue, and bucket IAM policies. A
GitHub Actions workflow applies `cron/k8s/{controller,worker,cii,auth}.yaml`
directly via `kubectl`, after `aws eks update-kubeconfig` and OIDC
authentication — the same deployment shape the manifests already assume.
Converting them into `kubernetes_manifest` Terraform resources would trade
away the one property that made EKS the right call under a one-person time
budget (**E1**) for no compensating benefit: the manifests port with registry
references and node-selectors adjusted, not rewritten.

The controller's existing narrow RBAC (`Role`/`RoleBinding` scoped to `get`,
`patch` on the `scorecard-batch-worker` Deployment, used to trigger a rollout
after publishing a shard) needs no AWS-side equivalent — it is a Kubernetes
API permission, and EKS's control plane is still a real Kubernetes API. This
is one of the concrete costs an ECS choice would have paid: ECS has no
equivalent primitive, and reproducing the same restart trigger would mean a
new `ecs:UpdateService` IAM grant plus rewriting the controller's restart
call entirely, not just retargeting it.

## State

**E9 — the existing state backend is reused, not re-bootstrapped.**
`deploy/cron/secrets` already writes into the same S3 state bucket
`deploy/api/bootstrap` created, under the key `cron/secrets/terraform.tfstate`.
This change adds sibling keys (e.g. `cron/production/terraform.tfstate`) in
the same bucket. No new `deploy/cron/bootstrap` root module.

The new root is `deploy/cron/production/`, flat under `deploy/cron/` —
matching `deploy/cron/secrets`'s existing layout, not `deploy/api`'s nested
`environments/{staging,production}/`. That nesting exists for the serving
plane because staging and production need materially different bucket
access (staging is read-only against production's data); no such split
exists for the batch plane, and inventing one to match a different plane's
directory shape would be cosmetic. If a batch staging/rehearsal tier is ever
needed, `deploy/cron/production/` becomes the sibling of a
`deploy/cron/staging/` at that point, not retroactively nested under an
`environments/` directory neither one needs.

## Verification approach

Mirrors `provision-aws`'s gate structure, adapted for a plane with no
internet-facing traffic to shadow-test:

1. Publish a small, explicit repository inventory to the queue.
2. Confirm the message stays invisible while a worker is actively scanning it
   (**E3**'s heartbeat).
3. Kill that worker mid-scan. Confirm the message becomes visible again,
   a second worker picks it up, and the result completes on retry.
4. Confirm no inconsistent output landed in the **test** buckets (**E7**) from
   the killed attempt — a partial write, a duplicate, or a result tagged with
   the wrong commit would all be signals to fix before pointing at production
   data.
5. Only after that passes does reconfiguring against the six adopted
   production buckets, and scheduling the production `cron/k8s/*.yaml`
   schedules, become the next change's job to gate and execute.

## What this change does not decide

- **The BigQuery/warehouse replacement.** Explicitly deferred; see the
  proposal's non-goals.
- **The release-test tier's fate.** Whether it still runs at all is
  unconfirmed; porting it is not this change's job.
- **`:stable` tag promotion.** Unrelated to where compute runs.
- **Node group autoscaling.** Start at the known baseline (**E1**); tuning is
  a follow-on once there is a real signal to tune against.
