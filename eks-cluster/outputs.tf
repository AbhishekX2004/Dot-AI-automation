# =============================================================================
# Cluster Identity
# =============================================================================

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster."
  value       = aws_eks_cluster.this.version
}

# =============================================================================
# Connectivity
# =============================================================================

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider (use this when creating IRSA roles)."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC issuer (without https://) — use in IRSA assume-role conditions."
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

# =============================================================================
# Networking
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC the cluster is deployed into."
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "IDs of the subnets used by the cluster and node group."
  value       = local.selected_subnet_ids
}

# =============================================================================
# Node Group
# =============================================================================

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.this.arn
}

output "node_group_status" {
  description = "Current status of the managed node group."
  value       = aws_eks_node_group.this.status
}

output "node_role_arn" {
  description = "ARN of the IAM role attached to worker nodes."
  value       = aws_iam_role.node_group.arn
}

# =============================================================================
# Handy Commands
# =============================================================================

output "kubeconfig_command" {
  description = "Run this command to update your local kubeconfig for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
