# General
variable "aws_region" {
  description = "AWS region where the client EKS cluster will be created."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label applied to all resources (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "client_name" {
  description = <<-EOT
    A short, unique name for this client (e.g. "acme-corp").
    Used as a suffix in the EKS cluster name and in resource tags.
    Must be lowercase with hyphens only.
  EOT
  type        = string
  default     = "client-1"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.client_name))
    error_message = "client_name must be lowercase letters, numbers, and hyphens only (e.g. acme-corp)."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}

# Networking — Default VPC
variable "azs_count" {
  description = <<-EOT
    Number of Availability Zones to spread the worker nodes across.
    Lower values reduce NAT/cross-AZ data-transfer costs.
    Must not exceed the number of AZs available in the chosen region.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.azs_count >= 1 && var.azs_count <= 6
    error_message = "azs_count must be between 1 and 6."
  }
}

# EKS Cluster
variable "cluster_name" {
  description = <<-EOT
    Name for the client EKS cluster. Must be unique within the region.
    If left empty, it will be auto-generated as "dot-ai-client-<client_name>".
  EOT
  type        = string
  default     = ""
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.35"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the Kubernetes API server endpoint is publicly accessible."
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Whether the Kubernetes API server is accessible from within the VPC."
  type        = bool
  default     = true
}

# Managed Node Group
variable "node_group_name" {
  description = "Name for the managed node group. If left empty, auto-generated."
  type        = string
  default     = ""
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes."
  type        = string
  default     = "t3.small"
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size (GiB) per node."
  type        = number
  default     = 20
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}

variable "node_capacity_type" {
  description = "Capacity type for managed node group: ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

# EKS Add-ons
variable "enable_coredns" {
  description = "Whether to install the coredns EKS managed add-on."
  type        = bool
  default     = true
}

variable "enable_kube_proxy" {
  description = "Whether to install the kube-proxy EKS managed add-on."
  type        = bool
  default     = true
}

variable "enable_vpc_cni" {
  description = "Whether to install the vpc-cni EKS managed add-on."
  type        = bool
  default     = true
}

variable "enable_ebs_csi_driver" {
  description = "Whether to install the aws-ebs-csi-driver EKS managed add-on (needed for PVCs backed by EBS)."
  type        = bool
  default     = true
}
