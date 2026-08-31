# Tasks: Provision the AWS batch scanning plane in OpenTofu

Decision tags **E1**–**E9** are defined in `design.md`.

## 1. Discovery

Run 2026-08-31 with `scripts/cutover/capture-aws.sh` and a new sibling,
`scripts/cutover/capture-aws-batch.sh`, which covers the DataSync, SQS
attribute, CloudWatch and route-table sections the first script has none of.

- [x] 1.1 Confirm the six corpus buckets (`ossf-scorecard-results`,
      `ossf-scorecard-cron-results`, `ossf-scorecard-data2`,
      `ossf-scorecard-rawdata`, `ossf-scorecard-input-projects`,
      `ossf-scorecard-cii-data`) are still present and still being written by
      DataSync, as `provision-aws` 1.4 found on 2026-08-29. Re-run
      `scripts/cutover/capture-aws.sh` rather than trust a five-day-old
      capture.
      **All six present in `us-east-1`. Versioning off, lifecycle absent,
      bucket policy absent, encryption and public-access-block present on
      every one — confirming E7's premise rather than assuming it. Newest
      date partition in `data2` and `rawdata` is `2026.08.24/`, matching the
      frozen corpus exactly. DataSync is still running but degrading; see the
      note under group 3.**
- [x] 1.2 Investigate the `openssf-scorecard` SQS queue (**E8**): its
      attributes, redrive policy (if any), and message count. Determine
      whether it is a leftover from an earlier attempt, an unwired
      placeholder, or already correctly shaped. Decide adopt-vs-create before
      **E2** is implemented.
      **Unwired placeholder, and not an old one: created 2026-08-26 by the
      account root user via the console, then tuned 2026-08-28
      (`VisibilityTimeout` 30→3600, `ReceiveMessageWaitTimeSeconds` 0→20).
      CloudWatch reports 0 sent / 0 received / 0 deleted on every day since
      creation — it has never carried a message. No redrive policy, no tags,
      SSE off, and its name matches neither `cron/config/config.yaml`'s topic
      (`scorecard-batch-requests`) nor its subscription. See 4.1.**
- [x] 1.3 Confirm no EKS cluster, no batch-plane application IAM roles, and no
      SQS consumer already exist, as `provision-aws` 1.7 found for the
      serving plane's equivalents.
      **Confirmed on all three. Zero EKS clusters. Of 29 IAM roles, none is a
      batch-plane application role — 8 service-linked, 8 Application
      Migration, 7 `AWSDataSyncS3BucketAccess-*`, 6 serving-plane roles
      created 2026-08-29. No consumer: zero Lambda event source mappings, and
      the queue's own receive count is zero for its whole lifetime.**
- [x] 1.4 Confirm the Elastic IP quota (5, shared by both planes per
      `provision-aws` 1.7) has enough headroom for the batch cluster's node
      groups' egress, given the serving plane's NAT Gateway is being shared
      (**E5**) rather than doubled.
      **Three of five free. `describe-addresses` returns six, which reads as a
      breach of a quota that has never been raised; it is not. Four are
      `RequesterManaged: true` under `amazon-elb`, on the two ALBs'
      interfaces, and service-managed addresses do not count against
      `L-0263D0A3`. Only the two NAT Gateway EIPs are self-allocated, which
      `deploy/`'s single `aws_eip` declaration corroborates. E5 stands on cost
      alone — there is no capacity argument for it.**

## 2. Toolchain and scaffolding

- [ ] 2.1 Create `deploy/cron/modules/{cluster,queue}/` and
      `deploy/cron/production/`, each with its own `terraform` block pinning
      `required_version >= 1.10` (matching `deploy/api` and
      `deploy/cron/secrets`).
- [ ] 2.2 `deploy/cron/production/`'s backend: S3, same state bucket
      `deploy/cron/secrets` uses, key `cron/production/terraform.tfstate`,
      `use_lockfile = true` (**E9**). No new bootstrap.
- [ ] 2.3 Tag convention matches `deploy/cron/secrets`: `Project = "scorecard"`,
      `Component = "cron"`, `ManagedBy = "opentofu"`,
      `Source = "ossf/scorecard-infra//deploy/cron/production"`.

## 3. Network

- [ ] 3.1 Determine how `deploy/cron/production/` reaches `deploy/api`'s VPC
      — a `terraform_remote_state` data source against `deploy/api`'s state,
      or a small shared network module both roots call. Decide before writing
      subnets (**E5**).
- [ ] 3.2 Add private subnets and route tables for the batch cluster inside
      that VPC, routed through the existing NAT Gateway. No new NAT Gateway,
      no new Elastic IP.
- [ ] 3.3 Confirm the existing S3 gateway endpoint (if `deploy/api` has one)
      covers the batch cluster's new subnets, or add the batch subnets to its
      route table association.
- [ ] 3.4 Create the three test buckets (**E7**): `ossf-scorecard-cron-results-test`,
      `ossf-scorecard-data2-test`, `ossf-scorecard-rawdata-test`. Private,
      versioning on (unlike the adopted production buckets, which have it
      off — no reason to inherit that gap in something created fresh).

## 4. Queue

- [ ] 4.1 Resolve **E8**: adopt `openssf-scorecard` or create a new queue,
      per task 1.2's finding.
- [ ] 4.2 Provision the SQS Standard queue and its DLQ (**E2**), with a
      finite `maxReceiveCount` redrive policy.
- [ ] 4.3 Size the visibility timeout default to comfortably exceed a typical
      scan's duration — this is a starting value the heartbeat (**E3**)
      extends, not the sole protection against redelivery.

## 5. Cluster

- [ ] 5.1 EKS cluster, one control plane, in the subnets from group 3.
- [ ] 5.2 System node group: sized for the controller CronJob (bursts to one
      pod once a week) and the `scorecard-github-server` Deployment
      (always-on, small).
- [ ] 5.3 Worker node group: sized for 14 workers (**E1**'s baseline),
      matching the current GKE `scorecard-batch-worker` Deployment replica
      count.
- [ ] 5.4 Pod Identity associations: a role per workload
      (controller/worker/github-server), each scoped to exactly what that
      workload needs — the queue actions its role requires, the buckets it
      reads/writes, and (worker, controller) `deploy/cron/secrets`'
      `read_policy_json` output.
- [ ] 5.5 The controller's Kubernetes RBAC (`Role`/`RoleBinding` scoped to
      `get`, `patch` on the `scorecard-batch-worker` Deployment) needs no
      AWS-side IAM equivalent — verify it applies to EKS's control plane
      unchanged (**E4**).
- [ ] 5.6 Verify denial, not only permission: confirm each role is refused
      access to the other planes' buckets/secrets and to the production
      corpus buckets from a role scoped to the test buckets, not only that
      its own grants work.

## 6. Code

- [ ] 6.1 Link `gocloud.dev/blob/s3blob` in `cron/data/blob.go` alongside
      `fileblob` and `gcsblob`.
- [ ] 6.2 Implement `cron/internal/pubsub/subscriber_sqs.go` (**E3**): long
      polling `ReceiveMessage`, an initial visibility timeout, a heartbeat
      goroutine calling `ChangeMessageVisibility` before expiry, `Ack` →
      `DeleteMessage`, `Nack` → `ChangeMessageVisibility` to zero, heartbeat
      stopped on ack/nack/shutdown/cancellation.
- [ ] 6.3 Add a matching SQS publisher alongside the existing GCP one in
      `cron/internal/pubsub/publisher.go`.
- [ ] 6.4 Switch subscriber/publisher selection to URL scheme
      (`gcppubsub://` vs `awssqs://`) rather than the current
      always-GCP-unless-emulated default.
- [ ] 6.5 Unit tests: heartbeat renewal, ack/nack/DLQ paths, a deliberately
      slow consumer that outlives one visibility window without losing the
      message, malformed URLs, and the existing GCP paths unchanged.
- [ ] 6.6 `go build ./...`, `go test ./... -race`, `golangci-lint run ./...`
      clean with both subscriber implementations compiled in.

## 7. Workload manifests

- [ ] 7.1 Port `cron/k8s/controller.yaml`, `worker.yaml`, `cii.yaml`,
      `auth.yaml` for EKS: node-selector/affinity for the two-node-group
      split (**E1**), the new `awssqs://` topic/subscription URLs, the AWS
      config overlay's bucket URLs (`s3://...` for the three write targets).
      Registry references already point at `ghcr.io` — no image changes.
- [ ] 7.2 Add an AWS config overlay (e.g. `deploy/cron/config-aws.yaml` or a
      ConfigMap generated from one) analogous to `cron/config/config.yaml`,
      pointing at the test buckets (**E7**) until group 9 passes, and leaving
      BigQuery fields disabled/absent — this change does not deploy the
      transfer jobs.
- [ ] 7.3 Confirm the `*.release.yaml` tier and `transfer*.yaml` are **not**
      ported — out of scope (proposal non-goals).

## 8. CI/deploy

- [ ] 8.1 GitHub Actions workflow: OIDC to AWS (constrained to this
      repository and a protected environment, matching `provision-aws`'s
      **A9**-adjacent pattern for the serving plane's deploy role),
      `aws eks update-kubeconfig`, `kubectl apply -f` the manifests from
      group 7.
- [ ] 8.2 Deploy by digest where the workflow can (image references already
      come from `publish-cron-images.yml`'s digest output); document where it
      still can't (e.g. `:stable`, per the open `migrate-batch-pipeline` 4.4
      question) rather than silently accepting a mutable tag.
- [ ] 8.3 `actionlint` and `zizmor` clean on the new workflow.

## 9. Verification

- [ ] 9.1 Publish a small, explicit repository inventory to the queue,
      pointed at the test buckets (**E7**) via the config overlay from 7.2.
- [ ] 9.2 Confirm the message stays invisible while a worker is actively
      scanning it (**E3**'s heartbeat holding the visibility timeout open).
- [ ] 9.3 Kill that worker mid-scan (e.g. `kubectl delete pod`). Confirm the
      message becomes visible again after the timeout, a second worker picks
      it up, and the result completes on retry.
- [ ] 9.4 Confirm no inconsistent output landed in the test buckets from the
      killed attempt — no partial write, no duplicate, nothing tagged with
      the wrong commit.
- [ ] 9.5 Confirm the DLQ receives a message that permanently fails (e.g. a
      deliberately malformed shard) after `maxReceiveCount` retries, rather
      than looping forever.
- [ ] 9.6 Confirm the CII worker completes one cycle against the test
      `cii-data` path (or documents why it was left pointed at the read-only
      production bucket, if a CII-specific test bucket turns out unnecessary
      — CII is lower-frequency and lower-risk per **E7**'s reasoning).
- [ ] 9.7 Only after 9.1–9.6 pass: repoint the config overlay at the six
      production buckets and the real `projects.csv`/`gitlab-projects.csv`
      inventories, but do **not** enable the production `cron/k8s/*.yaml`
      schedules yet — that activation, and the community notice question it
      may raise, is this change's last task before closeout, not an
      automatic consequence of verification passing.
- [ ] 9.8 `tofu fmt -check -recursive -diff deploy/cron/` and
      `tofu validate` (per-root, `-backend=false`) clean.

## 10. Documentation

- [ ] 10.1 Write `deploy/cron/README.md`, mirroring `deploy/api/README.md`'s
      shape: requirements, layout, apply order, an **Application
      configuration** table (env vars / config overlay keys mapped to the
      code that reads them, matching what `deploy/api/README.md`'s
      equivalent section now has), and what this deployment does not manage.
- [ ] 10.2 Update `AGENTS.md`'s `cron/` row and batch-pipeline section: GCP
      production is gone, AWS compute exists, pointing at
      `deploy/cron/README.md` for the runbook.
- [ ] 10.3 Update the root `README.md`'s batch scanning pipeline section with
      the AWS deployment path.

## 11. Closeout

- [ ] 11.1 `openspec validate provision-cron-aws --strict` passes.
- [ ] 11.2 Verify every success criterion in the proposal and design is met.
- [ ] 11.3 Archive the change once implemented and merged.
