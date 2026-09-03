#!/usr/bin/env bash
#
# Copyright 2026 OpenSSF Scorecard Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Batch-plane discovery (provision-cron-aws, task group 1).
#
#   ./capture-aws-batch.sh [output-dir]
#
# The sibling of capture-aws.sh, not a replacement for it. RUN BOTH: that one
# establishes the account-wide picture (buckets, IAM roles, EKS, VPCs, EIP
# quota) and this one answers the four questions group 1 asks that it has no
# section for --
#
#   1.1  Is DataSync STILL WRITING to the corpus buckets? capture-aws.sh proves
#        the buckets exist; it never calls DataSync at all, and "exists" and
#        "is still being fed" are different facts. Answered here two ways: the
#        DataSync task execution history, and the newest date partition in the
#        two date-partitioned buckets (cron/data/blob.go:35 -- "2006.01.02/").
#
#   1.2  What IS the pre-existing `openssf-scorecard` queue (E8)? capture-aws.sh
#        runs `sqs list-queues`, which returns a URL and nothing else. Whether
#        that queue is a live topic, an abandoned first attempt, or a
#        never-wired placeholder is the whole question, and it is answered by
#        its attributes, its redrive policy, and -- decisively -- whether any
#        message has ever moved through it. Hence the CloudWatch and CloudTrail
#        sections: an empty queue looks identical whether it drained yesterday
#        or was never used.
#
#   1.3  Is there an SQS CONSUMER? Also a CloudWatch question, not a describe-*
#        one. Nothing in the AWS API reports "a consumer exists"; the evidence
#        is NumberOfMessagesReceived over a long window.
#
#   3.1/3.2/3.3  Route tables. capture-aws.sh captures VPCs, subnets, NAT
#        gateways and endpoints, but not route tables -- and E5 shares
#        deploy/api's VPC, so the batch subnets' routing to the existing NAT
#        Gateway and the S3 gateway endpoint's route table associations are
#        what the network tasks are written against.
#
# Deliberately narrower than its sibling in one respect: it names the six
# corpus buckets explicitly rather than sweeping the account. The account holds
# at least one bucket that is not ours, and this repository is public.
#
# ON "SSL validation failed ... self-signed certificate in certificate chain":
# that is TLS interception, not a permissions problem, and capture-aws.sh's
# header explains at length why the two are easy to confuse.
#
# Its advice -- get off the intercepting network -- did not work on the first
# two runs here, and the reason is worth recording. The interception was
# ENDPOINT-SELECTIVE: every call to s3.* and monitoring.* failed while sqs,
# ec2, iam, datasync, cloudtrail, lambda, servicequotas and sts all succeeded
# in the same run. That profile survives disconnecting from a VPN, and it
# produces the single most misleading output this script can emit -- a
# summary in which S3 is uniformly broken and everything around it looks
# healthy, which reads as "no bucket access" rather than "no TLS trust".
#
# What fixed it: the AWS CLI bundles its own CA store (certifi) and never
# consults the macOS keychain, which is where an administratively-installed
# interception root actually lives -- hence browsers working while this fails.
# Export both keychains and point the CLI at them:
#
#   { security find-certificate -a -p \
#       /System/Library/Keychains/SystemRootCertificates.keychain
#     security find-certificate -a -p /Library/Keychains/System.keychain
#   } > /tmp/aws-ca-bundle.pem
#   export AWS_CA_BUNDLE=/tmp/aws-ca-bundle.pem
#
# Do NOT reach for --no-verify-ssl. It turns a loud, diagnosable trust failure
# into a silent one, and every finding this script produces would then rest on
# an unauthenticated connection.
#
# Read-only throughout. No secret values are fetched, and nothing is created,
# modified, or consumed -- in particular the SQS sections never call
# ReceiveMessage, which would start a visibility timer on a real message.
# Output is gitignored, because ARNs carry the account ID.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${SCRIPT_DIR}/out/aws-batch-$(date -u +%Y%m%dT%H%M%SZ)}"

# Region is settled, not chosen: provision-aws A5 established us-east-1 because
# that is where the corpus buckets are. Override only if that ever stops being
# true.
REGION="${AWS_REGION:-us-east-1}"

# The six corpus buckets (design E6). Named rather than swept -- see the header.
CORPUS_BUCKETS="ossf-scorecard-results ossf-scorecard-cron-results \
ossf-scorecard-data2 ossf-scorecard-rawdata ossf-scorecard-input-projects \
ossf-scorecard-cii-data"

# The three written by a normal scan cycle are the ones whose freshness matters
# for 1.1. Of those, data2 and rawdata are date-partitioned and can be probed
# by listing prefixes; cron-results is keyed by repository, so its freshness
# comes from the DataSync section instead.
DATED_BUCKETS="ossf-scorecard-data2 ossf-scorecard-rawdata"

export AWS_PAGER=""

command -v aws >/dev/null || { echo "error: the AWS CLI is required" >&2; exit 1; }
command -v jq  >/dev/null || { echo "error: jq is required" >&2; exit 1; }

if [ -e "${OUT}/.git" ]; then
  echo "error: refusing to write into a repository root: ${OUT}" >&2
  exit 1
fi

mkdir -p "${OUT}" || exit 1
SUMMARY="${OUT}/SUMMARY.txt"
: > "${SUMMARY}"
note() { echo "$*" | tee -a "${SUMMARY}"; }

# The AWS CLI prints a blank line before its error, so `head -1` on a .err file
# yields an empty string. capture-aws.sh learned this the expensive way.
first_error() { grep -m1 '[^[:space:]]' "$1" 2>/dev/null; }

# Distinguish a LIST response ({"Tasks": [...]}) from a DETAIL response
# ({"Name": "x", "Status": "AVAILABLE", "Includes": [], "Excludes": []}).
#
# The first real run reported all twenty `datasync describe-task` calls as
# "empty -- 200, zero items" when every one of them had returned a full task
# definition. The inherited heuristic took the first array-valued key it found,
# which for describe-task is `Includes`, and DataSync returns that empty on a
# task with no filter rules. The data was on disk the whole time; the summary
# said it was not. That is precisely the failure capture-aws.sh's header
# records twice over -- a section that reports nothing looks identical to a
# section that found nothing.
#
# The rule that separates them: a list response has exactly one array-valued
# key. A detail response has several (or none, and scalars besides).
item_count() {
  jq -r '
    if type == "array" then length
    elif type == "object" then
      ([to_entries[] | select(.key != "ResponseMetadata")
        | select(.value | type == "array")]) as $arrays
      | if ($arrays | length) == 1 then ($arrays[0].value | length) else empty end
    else empty end
  ' "$1" 2>/dev/null
}

capture() {
  local slug="$1" desc="$2"
  shift 2
  if aws "$@" > "${OUT}/${slug}.json" 2> "${OUT}/${slug}.err"; then
    local n
    n="$(item_count "${OUT}/${slug}.json")"
    if [ ! -s "${OUT}/${slug}.json" ] ||
       [ "$(tr -d '[:space:]' < "${OUT}/${slug}.json")" = "null" ] ||
       [ "$(tr -d '[:space:]' < "${OUT}/${slug}.json")" = "{}" ]; then
      note "none     ${slug}  -- ${desc} (200, nothing configured)"
    elif [ "${n}" = "0" ]; then
      note "empty    ${slug}  -- ${desc} (200, zero items)"
    elif [ -n "${n}" ]; then
      note "ok  [${n}]  ${slug}  -- ${desc}"
    else
      note "ok       ${slug}  -- ${desc}"
    fi
    rm -f "${OUT}/${slug}.err"
  else
    local err
    err="$(first_error "${OUT}/${slug}.err")"
    # AWS.SimpleQueueService.NonExistentQueue is an answer, not a failure.
    if echo "${err}" | grep -qE 'NonExistentQueue|ResourceNotFound'; then
      note "none     ${slug}  -- ${desc} (does not exist)"
      rm -f "${OUT}/${slug}.err"
      return
    fi
    note "FAILED   ${slug}  -- ${desc}"
    note "         ${err}"
  fi
}

# BSD date on macOS, GNU date elsewhere. The sibling scripts avoid `mapfile`
# for the same reason: this runs from a maintainer's laptop shipping bash 3.2.
days_ago() {
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
D90="$(days_ago 90)"

if ! aws sts get-caller-identity > "${OUT}/caller-identity.json" \
     2> "${OUT}/caller-identity.err"; then
  note "error: the AWS CLI has no usable credentials."
  note "       $(head -3 "${OUT}/caller-identity.err" | tr '\n' ' ')"
  note ""
  note "  An SSL certificate error here is a trust-store problem, not a"
  note "  credential one. Leaving the VPN may not clear it -- the interception"
  note "  seen here was endpoint-selective. Export the system keychains and"
  note "  point the CLI at them (see this script's header):"
  note "    export AWS_CA_BUNDLE=/tmp/aws-ca-bundle.pem"
  exit 1
fi

note "AWS batch-plane capture   date: ${NOW}"
note "account:  $(jq -r '.Account // "unknown"' "${OUT}/caller-identity.json")"
note "identity: $(jq -r '.Arn // "unknown"' "${OUT}/caller-identity.json")"
note "region:   ${REGION}"
note ""

# ---------------------------------------------------------------------------
# 1.2 / 1.3 / E8 -- what the pre-existing SQS queue actually is
# ---------------------------------------------------------------------------

note "== SQS (task 1.2, E8) =="
capture sqs-queues "queues in ${REGION}" \
  sqs list-queues --region "${REGION}"

QUEUE_URLS=""
while IFS= read -r line; do
  [ -n "${line}" ] && QUEUE_URLS="${QUEUE_URLS} ${line}"
done < <(jq -r '.QueueUrls[]? // empty' "${OUT}/sqs-queues.json" 2>/dev/null)

if [ -z "${QUEUE_URLS// /}" ]; then
  note "  no queues returned -- E8 resolves to 'create', but confirm this is"
  note "  not a permissions artifact before acting on it."
else
  for qurl in ${QUEUE_URLS}; do
    qname="${qurl##*/}"
    note ""
    note "  queue: ${qname}"

    # Everything: VisibilityTimeout, RedrivePolicy, RedriveAllowPolicy,
    # CreatedTimestamp, ApproximateNumberOfMessages{,NotVisible,Delayed},
    # MessageRetentionPeriod, ReceiveMessageWaitTimeSeconds, KmsMasterKeyId,
    # FifoQueue, Policy, QueueArn. CreatedTimestamp is the single most useful
    # field for E8: it dates the queue against the migration timeline.
    capture "sqs-attrs-${qname}" "  ${qname} attributes (all)" \
      sqs get-queue-attributes --region "${REGION}" \
        --queue-url "${qurl}" --attribute-names All

    capture "sqs-tags-${qname}" "  ${qname} tags (who made it, if anyone said)" \
      sqs list-queue-tags --region "${REGION}" --queue-url "${qurl}"

    # If this queue is already somebody's DLQ, adopting it would be a mistake
    # no attribute on the queue itself reveals.
    capture "sqs-dlq-sources-${qname}" "  ${qname} dead-letter source queues" \
      sqs list-dead-letter-source-queues --region "${REGION}" --queue-url "${qurl}"

    # The decisive evidence. An empty queue looks the same whether it drained
    # an hour ago or has never held a message; these three metrics tell those
    # apart, and NumberOfMessagesReceived is the only real answer to task 1.3's
    # "is there a consumer". Daily sums over 90 days -- the CloudWatch
    # retention ceiling for this resolution.
    for metric in NumberOfMessagesSent NumberOfMessagesReceived NumberOfMessagesDeleted; do
      capture "sqs-metric-${qname}-${metric}" "  ${qname} ${metric} (90d, daily sum)" \
        cloudwatch get-metric-statistics --region "${REGION}" \
          --namespace AWS/SQS --metric-name "${metric}" \
          --dimensions "Name=QueueName,Value=${qname}" \
          --start-time "${D90}" --end-time "${NOW}" \
          --period 86400 --statistics Sum
    done

    # Who created it and when. Two queries, because the first run showed the
    # ResourceName lookup alone is not trustworthy here: it returned zero
    # events for a queue whose own CreatedTimestamp puts its creation five
    # days ago, comfortably inside CloudTrail's 90-day management-event
    # window. Either SQS does not populate the resourceName field the way this
    # lookup expects, or the event is indexed only by name. A zero from ONE of
    # these proves nothing; a zero from BOTH is evidence.
    capture "sqs-cloudtrail-byresource-${qname}" \
      "  ${qname} CloudTrail by ResourceName (90d)" \
      cloudtrail lookup-events --region "${REGION}" \
        --lookup-attributes "AttributeKey=ResourceName,AttributeValue=${qname}" \
        --start-time "${D90}" --end-time "${NOW}"
    capture "sqs-cloudtrail-createqueue" \
      "  CreateQueue events across the account (90d)" \
      cloudtrail lookup-events --region "${REGION}" \
        --lookup-attributes "AttributeKey=EventName,AttributeValue=CreateQueue" \
        --start-time "${D90}" --end-time "${NOW}"
    capture "sqs-cloudtrail-setattrs" \
      "  SetQueueAttributes events across the account (90d)" \
      cloudtrail lookup-events --region "${REGION}" \
        --lookup-attributes "AttributeKey=EventName,AttributeValue=SetQueueAttributes" \
        --start-time "${D90}" --end-time "${NOW}"
  done
fi

# A consumer need not be a pod. Nothing in the account should have an SQS
# trigger yet, and this is a direct check rather than the inference CloudWatch
# gives -- which matters because the CloudWatch sections are the ones that
# failed on the first run.
capture lambda-event-source-mappings "Lambda SQS triggers (expected: none)" \
  lambda list-event-source-mappings --region "${REGION}"

# ---------------------------------------------------------------------------
# 1.1 -- is DataSync still writing?
# ---------------------------------------------------------------------------

note ""
note "== DataSync (task 1.1) =="
capture datasync-tasks "DataSync tasks" \
  datasync list-tasks --region "${REGION}"
capture datasync-locations "DataSync locations" \
  datasync list-locations --region "${REGION}"

TASK_ARNS=""
while IFS= read -r line; do
  [ -n "${line}" ] && TASK_ARNS="${TASK_ARNS} ${line}"
done < <(jq -r '.Tasks[]?.TaskArn // empty' "${OUT}/datasync-tasks.json" 2>/dev/null)

if [ -z "${TASK_ARNS// /}" ]; then
  note "  no DataSync tasks -- if the buckets are still current, something"
  note "  other than DataSync is feeding them. Do not assume; find out."
else
  i=0
  for tarn in ${TASK_ARNS}; do
    i=$((i + 1))
    capture "datasync-task-${i}" "  task ${i} detail (schedule, source, dest)" \
      datasync describe-task --region "${REGION}" --task-arn "${tarn}"
    # Execution history is the actual answer to "still being written": a task
    # can exist, be scheduled, and have failed every run for a week.
    capture "datasync-task-${i}-executions" "  task ${i} execution history" \
      datasync list-task-executions --region "${REGION}" --task-arn "${tarn}"

    # list-task-executions returns ARNs and a Status and NO TIMESTAMP, which
    # the first run made painfully clear: a column of SUCCESS with one ERROR
    # in it says nothing about whether the ERROR is the most recent run or six
    # weeks old. That distinction is the whole of task 1.1 right now, because
    # every one of these tasks sources from storage.googleapis.com and the
    # GCP project behind it was turned down on 2026-08-31. Describe the three
    # newest executions so StartTime, BytesTransferred and any error detail
    # are on disk.
    #
    # `| tail -3`, and the tail is load-bearing: list-task-executions returns
    # OLDEST FIRST. The first version of this block took the first three and
    # reported them as the newest, which for the cron-results task meant
    # reading executions 1-3 of 60 and concluding replication was healthy on
    # the strength of runs from four days earlier. Ordering is not documented;
    # it was confirmed empirically across all six scheduled tasks, and
    # StartTime is in each output so a future reversal is visible rather than
    # silent.
    j=0
    while IFS= read -r xarn; do
      [ -z "${xarn}" ] && continue
      j=$((j + 1))
      capture "datasync-task-${i}-exec-${j}" "    task ${i} newest execution ${j}" \
        datasync describe-task-execution --region "${REGION}" \
          --task-execution-arn "${xarn}"
    done < <(jq -r '.TaskExecutions[]?.TaskExecutionArn // empty' \
               "${OUT}/datasync-task-${i}-executions.json" 2>/dev/null | tail -3)
  done
fi

# ---------------------------------------------------------------------------
# 1.1 -- corpus bucket freshness, independent of DataSync's own reporting
# ---------------------------------------------------------------------------

note ""
note "== corpus bucket freshness (task 1.1) =="
note "  newest date partitions; the corpus is expected frozen at 2026.08.24"
note "  (cron stopped 2026-08-30, last completed cycle 2026-08-24 02:00 UTC),"
note "  so a LATER partition means something is still writing and a much"
note "  EARLIER one means replication stopped before cron did."
for b in ${DATED_BUCKETS}; do
  # Date partitions are "YYYY.MM.DD/" (cron/data/blob.go:35), zero-padded, so
  # lexicographic order is chronological order. Scoped by year prefix to stay
  # inside one 1000-key page rather than paging through the full history.
  for yr in "$(date -u +%Y)" "$(( $(date -u +%Y) - 1 ))"; do
    out="$(aws s3api list-objects-v2 --region "${REGION}" --bucket "${b}" \
             --delimiter / --prefix "${yr}." \
             --query 'CommonPrefixes[*].Prefix' --output text 2>/dev/null \
           | tr '\t' '\n' | grep -v '^$' | sort | tail -3)"
    if [ -n "${out}" ]; then
      note "  ${b}  newest partitions:"
      echo "${out}" | while IFS= read -r p; do note "      ${p}"; done
      break
    fi
  done
done

# Object-level timestamps for the repository-keyed bucket, which has no date
# partitions to read. Also the bucket deploy/api serves from, so its state is
# not only a corpus question (E7).
capture "bucket-cron-results-sample" \
  "  ossf-scorecard-cron-results sample keys + LastModified" \
  s3api list-objects-v2 --region "${REGION}" \
    --bucket ossf-scorecard-cron-results --max-items 5

for b in ${CORPUS_BUCKETS}; do
  capture "bucket-${b}-head" "  ${b} reachable / owned" \
    s3api head-bucket --region "${REGION}" --bucket "${b}"
done

# ---------------------------------------------------------------------------
# 3.1 / 3.2 / 3.3 -- the network deploy/api built, which E5 shares
# ---------------------------------------------------------------------------

note ""
note "== network (tasks 3.1-3.3, E5) =="
capture route-tables "route tables (NOT in capture-aws.sh; 3.2 needs them)" \
  ec2 describe-route-tables --region "${REGION}"
capture vpcs "VPCs (deploy/api's, plus the default)" \
  ec2 describe-vpcs --region "${REGION}"
capture subnets "subnets (which CIDRs are taken -- 3.2 picks around these)" \
  ec2 describe-subnets --region "${REGION}"
capture vpc-endpoints "VPC endpoints (S3 gateway + its route table associations, 3.3)" \
  ec2 describe-vpc-endpoints --region "${REGION}"
capture nat-gateways "NAT gateways (E5 shares this one; there must be exactly one)" \
  ec2 describe-nat-gateways --region "${REGION}"
capture availability-zones "AZs (how many node groups can spread)" \
  ec2 describe-availability-zones --region "${REGION}"

# ---------------------------------------------------------------------------
# 1.3 / 1.4 -- negative checks and headroom
# ---------------------------------------------------------------------------

note ""
note "== compute and quota (tasks 1.3, 1.4) =="
capture eks-clusters "EKS clusters (expected: none)" \
  eks list-clusters --region "${REGION}"
capture iam-roles "IAM roles (expected: the 21 from 2026-08-29 + provision-aws's)" \
  iam list-roles
capture eips "Elastic IPs in use (quota is 5, shared by both planes)" \
  ec2 describe-addresses --region "${REGION}"
capture quota-eip "Elastic IP quota" \
  service-quotas list-service-quotas --service-code ec2 --region "${REGION}" \
    --query "Quotas[?contains(QuotaName, 'Elastic IP')]"
capture quota-eks "EKS quotas" \
  service-quotas list-service-quotas --service-code eks --region "${REGION}"
# Subnets-per-VPC and route-tables-per-VPC bound how many the batch cluster can
# add inside deploy/api's VPC -- a limit that only matters because E5 shares it.
capture quota-vpc "VPC quotas (subnets and route tables per VPC)" \
  service-quotas list-service-quotas --service-code vpc --region "${REGION}"

note ""
note "Read these first:"
note "  * sqs-attrs-*.json -- CreatedTimestamp, RedrivePolicy,"
note "    ApproximateNumberOfMessages. This is E8."
note "  * sqs-metric-*-NumberOfMessagesReceived.json -- if every Sum is absent"
note "    or zero across 90 days, nothing has ever consumed that queue, and"
note "    'unwired placeholder' stops being a guess (tasks 1.2 and 1.3)."
note "  * datasync-task-*-executions.json -- Status and StartTime of the most"
note "    recent run. 'Task exists' is not 'task is succeeding'."
note "  * the newest date partitions above -- cross-check against the frozen"
note "    corpus date rather than reading them in isolation."
note "  * route-tables.json + vpc-endpoints.json -- 3.3 needs to know which"
note "    route tables the S3 gateway endpoint is associated with today."
note ""
note "FAILED markers: on a first run these are more likely to be defects in"
note "this script than facts about the account. That is how the GCP capture"
note "went, twice, and how capture-aws.sh's first run went."
note ""
note "Contains account identifiers (ARNs). Output is gitignored; read before"
note "sharing. No secret values are fetched; nothing is written or consumed."
note ""
note "Summary written to ${SUMMARY}"
