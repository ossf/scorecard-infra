# The EKS cluster, its two node groups, and Pod Identity for the three
# workloads task 5.4 names (E1, E4). OpenTofu stops here: workload manifests
# themselves are group 7's job, applied via CI in group 8 (E4) -- this module
# never declares a Kubernetes resource, only the AWS-side scaffolding a
# kubectl apply needs to land against.
#
# IMPORTANT, load-bearing finding for group 7 (task 7.1): none of
# cron/k8s/{controller,worker,auth}.yaml sets serviceAccountName today, so all
# three implicitly run as the "default" ServiceAccount. EKS Pod Identity
# associates one IAM role per (cluster, namespace, service account) tuple --
# three workloads sharing one ServiceAccount could only ever get one shared
# role, which would hand the controller and github-server the worker's queue
# and bucket access, and vice versa. Every association below therefore names
# a workload-specific ServiceAccount that does not exist in the manifests
# yet. Group 7.1 MUST add serviceAccountName (and the ServiceAccount object
# itself) to each manifest, matching the var.*_service_account values this
# module defaults to -- and controller.yaml's RoleBinding subject needs the
# same update, away from "default".

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
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

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = var.subnet_ids
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

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
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

# EKS Pod Identity itself is delivered as an addon, not a node-role policy,
# but the agent still runs as a DaemonSet on every node -- no extra IAM here.

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.system_instance_type]

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

# --- Pod Identity: controller ----------------------------------------------

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

resource "aws_iam_role_policy" "controller_secrets" {
  name   = "secrets"
  role   = aws_iam_role.controller.id
  policy = var.secrets_read_policy_json
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
    sid       = "WriteTestResults"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = flatten([for arn in values(var.test_bucket_arns) : [arn, "${arn}/*"]])
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

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

# --- Pod Identity: github-server -------------------------------------------
#
# No queue, no bucket -- cron/k8s/auth.yaml's only credential need is the
# github secret's token key. A narrower policy than controller/worker's
# combined secrets_read_policy_json, scoped to exactly that one secret.

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
