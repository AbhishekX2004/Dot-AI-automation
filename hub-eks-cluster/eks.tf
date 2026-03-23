# =============================================================================
# IAM — EKS Cluster Role
# =============================================================================

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Required for EKS to manage ENIs on your behalf.
resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# =============================================================================
# Security Group — Cluster (additional / optional extra rules)
# EKS automatically creates its own managed SG; this one is for custom rules.
# =============================================================================

resource "aws_security_group" "eks_cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Additional security group for EKS cluster ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id

  # Allow all outbound by default.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

# =============================================================================
# EKS Cluster
# =============================================================================

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = local.selected_subnet_ids
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = var.cluster_endpoint_public_access
    endpoint_private_access = var.cluster_endpoint_private_access
  }

  # Enable control-plane logging to CloudWatch (free retention in /aws/eks/).
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  tags = {
    Name = var.cluster_name
  }
}

# =============================================================================
# OIDC Provider (needed for IRSA — IAM Roles for Service Accounts)
# =============================================================================

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-oidc"
  }
}

# =============================================================================
# IAM — Managed Node Group Role
# =============================================================================

data "aws_iam_policy_document" "node_group_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node_group" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_group_assume_role.json
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EBS CSI driver needs this to manage volumes (now explicitly using IRSA instead of node role directly).
data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  count              = var.enable_ebs_csi_driver ? 1 : 0
  name               = "${var.cluster_name}-ebs-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role[0].json
}

resource "aws_iam_role_policy_attachment" "node_ebs_csi" {
  count      = var.enable_ebs_csi_driver ? 1 : 0
  role       = aws_iam_role.ebs_csi_driver[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# =============================================================================
# Managed Node Group
# =============================================================================

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node_group.arn

  # Spread nodes across the selected subnets.
  subnet_ids = local.selected_subnet_ids

  # Instance configuration.
  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size_gb
  capacity_type  = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Rolling update strategy — replace nodes one at a time.
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]

  tags = {
    Name = var.node_group_name
  }

  # Lifecycle: ignore desired_size so external autoscalers can change it freely.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# =============================================================================
# EKS Add-ons
# Each add-on resolves to the latest default version for the cluster version.
# =============================================================================

resource "aws_eks_addon" "coredns" {
  count                       = var.enable_coredns ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  count                       = var.enable_kube_proxy ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "vpc_cni" {
  count                       = var.enable_vpc_cni ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count                       = var.enable_ebs_csi_driver ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver[0].arn

  configuration_values = jsonencode({
    defaultStorageClass = {
      enabled = true
    }
  })

  depends_on = [aws_eks_node_group.this]
}
