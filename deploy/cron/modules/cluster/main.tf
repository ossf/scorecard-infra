# The EKS cluster, its two node groups, and Pod Identity for the four
# workloads cron/k8s/*.yaml runs (E1, E4). OpenTofu stops here: workload
# manifests themselves are group 7's job, applied via CI in group 8 (E4) --
# this module never declares a Kubernetes resource, only the AWS-side
# scaffolding a kubectl apply needs to land against.
#
# IMPORTANT, load-bearing findings for group 7 (task 7.1). Two separate
# manifest changes are required before anything here works:
#
#   1. ServiceAccounts. None of cron/k8s/{controller,worker,cii,auth}.yaml
#      sets serviceAccountName today, so all four implicitly run as the
#      "default" ServiceAccount. EKS Pod Identity associates one IAM role per
#      (cluster, namespace, service account) tuple -- four workloads sharing
#      one ServiceAccount could only ever get one shared role, which would
#      hand every workload every other workload's access. Each association
#      below names a workload-specific ServiceAccount that does not exist in
#      the manifests yet. Group 7.1 MUST create each ServiceAccount object and
#      set serviceAccountName, matching this module's var.*_service_account
#      defaults -- and controller.yaml's RoleBinding subject needs the same
#      update, away from "default".
#
#   2. nodeSelector and tolerations. The worker pool is tainted (see below) so
#      that E1's whole reason for two pools -- batch workers never crowding
#      out the controller or the token server -- is enforced by the scheduler
#      rather than left to chance. worker.yaml must gain a matching toleration
#      and a nodeSelector; the other three want a nodeSelector for the system
#      pool. A forgotten toleration fails loudly (pods stay Pending) instead
#      of silently recreating the contention the split exists to prevent.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Node label and taint key. Both pools carry the label; only the worker pool
  # carries the taint.
  pool_key = "scorecard.dev/pool"

  # The worker writes scan output to these three (E7). Deliberately NOT the
  # whole of var.test_bucket_arns: cii_data belongs to the CII worker alone,
  # and a worker that can write it would erase the point of giving the CII
  # job its own role.
  worker_bucket_keys = ["cron_results", "data2", "rawdata"]
}

# --- Cluster ------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Declared rather than left to EKS, which would create it on first log write
# with retention set to "never expire" -- the same slow cost leak
# deploy/api/modules/service's log group calls out. Must exist before the
# cluster starts logging into it, hence the depends_on below.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  # Control-plane audit trail. Off by default in EKS, which means a cluster
  # holding the corpus's write credentials would have no record of who called
  # the API. "api", "audit" and "authenticator" are the three that answer
  # that question; the scheduler and controller-manager logs are debugging
  # aids this plane has no standing need for.
  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids = var.subnet_ids

    # Private access keeps node-to-API traffic inside the VPC rather than
    # hairpinning through the shared NAT Gateway, which matters here because
    # E5 shares that NAT with the serving plane and its data processing is
    # billed. Public access stays on because group 8's CI deploy runs on
    # GitHub-hosted runners, which have no stable egress range to allowlist --
    # so public_access_cidrs is left open and IAM, not the network, is the
    # access control. Tighten both if CI ever moves into the VPC.
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode = "API"

    # Without this, EKS's modern API auth mode grants nobody access,
    # including whoever runs this apply -- there is no legacy aws-auth
    # ConfigMap to fall back on. This grants whichever principal applies the
    # cluster admin access, so a human always has a way in even before
    # group 8's CI deploy role exists to get its own access entry.
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --- Node groups ----------------------------------------------------------
#
# One IAM role shared by both groups -- nothing here differs by workload,
# only by pod scheduling, and per-workload access lives in Pod Identity
# below, not node-level IAM.

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Sized for CoreDNS (two replicas, which want two nodes) plus the controller
# CronJob and the token server. Untainted, so cluster-wide DaemonSets and
# add-on control components land here rather than on tainted worker nodes.
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.system_instance_type]
  disk_size       = var.system_disk_size

  labels = { (local.pool_key) = "system" }

  scaling_config {
    desired_size = var.system_desired_size
    min_size     = var.system_min_size
    max_size     = var.system_max_size
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_node_group" "worker" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-worker"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.worker_instance_type]
  disk_size       = var.worker_disk_size

  labels = { (local.pool_key) = "worker" }

  # E1's two-pool split is only real if something enforces it. Without this
  # taint the scheduler is free to place 14 scanning pods on the system node
  # and the controller on a worker node, which is exactly the contention the
  # split exists to prevent. Group 7.1 adds the matching toleration to
  # worker.yaml; EKS's own DaemonSet add-ons (pod-identity-agent, vpc-cni,
  # kube-proxy) tolerate all taints and are unaffected.
  taint {
    key    = local.pool_key
    value  = "worker"
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    desired_size = var.worker_desired_size
    min_size     = var.worker_min_size
    max_size     = var.worker_max_size
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# EKS Pod Identity is delivered as an addon, not a node-role policy, but the
# agent runs as a DaemonSet -- so it needs nodes to run on. Created against a
# cluster with zero nodes it settles at DEGRADED, which the AWS provider
# surfaces as an apply error rather than a warning. Hence the ordering.
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"

  tags = var.tags

  depends_on = [
    aws_eks_node_group.system,
    aws_eks_node_group.worker,
  ]
}

# --- Pod Identity: controller ----------------------------------------------
#
# No secrets policy, unlike an earlier draft of this module. cron's controller
# reads no credential: there is no os.Getenv anywhere in
# cron/internal/controller/, and controller.yaml carries no secretKeyRef. It
# publishes shards and reads the project inventory, nothing more.

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.name}-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "PublishShards"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "ReadInputProjects"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.input_projects_bucket_arn, "${var.input_projects_bucket_arn}/*"]
  }

  statement {
    sid       = "ShardCompletionState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [var.test_bucket_arns["data2"], "${var.test_bucket_arns["data2"]}/*"]
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = var.controller_service_account
  role_arn        = aws_iam_role.controller.arn
}

# --- Pod Identity: worker ---------------------------------------------------

resource "aws_iam_role" "worker" {
  name               = "${var.name}-worker"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "ConsumeShards"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }

  statement {
    sid     = "WriteTestResults"
    actions = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = flatten([
      for k in local.worker_bucket_keys : [
        var.test_bucket_arns[k],
        "${var.test_bucket_arns[k]}/*",
      ]
    ])
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

# The only workload that reads more than one secret: the GitHub App
# credentials, the GitLab token, and the Fastly purge token (optional -- the
# worker logs "CDN purging disabled" and continues without it, see
# cron/internal/worker/main.go).
resource "aws_iam_role_policy" "worker_secrets" {
  name   = "secrets"
  role   = aws_iam_role.worker.id
  policy = var.secrets_read_policy_json
}

resource "aws_eks_pod_identity_association" "worker" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = var.worker_service_account
  role_arn        = aws_iam_role.worker.arn
}

# --- Pod Identity: CII worker -----------------------------------------------
#
# The fourth workload, and the narrowest. cron/internal/cii/main.go fetches the
# OpenSSF Best Practices pages over plain HTTP and writes them to one bucket.
# No queue, no credential, no other storage.

resource "aws_iam_role" "cii" {
  name               = "${var.name}-cii"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "cii" {
  statement {
    sid       = "WriteCIIData"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [var.test_bucket_arns["cii_data"], "${var.test_bucket_arns["cii_data"]}/*"]
  }
}

resource "aws_iam_role_policy" "cii" {
  name   = "cii"
  role   = aws_iam_role.cii.id
  policy = data.aws_iam_policy_document.cii.json
}

resource "aws_eks_pod_identity_association" "cii" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = var.cii_service_account
  role_arn        = aws_iam_role.cii.arn
}

# --- Pod Identity: github-server -------------------------------------------
#
# No queue, no bucket -- cron/k8s/auth.yaml's only credential need is the
# github secret's token key. A narrower policy than the worker's combined
# secrets_read_policy_json, scoped to exactly that one secret.

resource "aws_iam_role" "github_server" {
  name               = "${var.name}-github-server"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "github_server" {
  statement {
    sid       = "ReadGithubSecretOnly"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.github_secret_arn]
  }
}

resource "aws_iam_role_policy" "github_server" {
  name   = "secrets"
  role   = aws_iam_role.github_server.id
  policy = data.aws_iam_policy_document.github_server.json
}

resource "aws_eks_pod_identity_association" "github_server" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = var.github_server_service_account
  role_arn        = aws_iam_role.github_server.arn
}
