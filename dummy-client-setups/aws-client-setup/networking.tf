# Look up the default VPC in the chosen region.
data "aws_vpc" "default" {
  default = true
}

# Pull all AZs available in the region.
data "aws_availability_zones" "available" {
  state = "available"
}

# Pull every default subnet (one per AZ) that lives in the default VPC.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "defaultForAz"
    values = ["true"]
  }
}

# Slice the list to respect var.azs_count
locals {
  # Resolve cluster name: use var.cluster_name if set, otherwise auto-generate.
  resolved_cluster_name    = var.cluster_name != "" ? var.cluster_name : "dot-ai-client-${var.client_name}"
  resolved_node_group_name = var.node_group_name != "" ? var.node_group_name : "${local.resolved_cluster_name}-nodes"

  # Use only the first azs_count subnets.
  selected_subnet_ids = slice(
    tolist(data.aws_subnets.default.ids),
    0,
    min(var.azs_count, length(data.aws_subnets.default.ids))
  )
}

# EKS requires specific tags on the subnets it uses.
# We tag the *default* subnets in-place rather than creating new ones.
resource "aws_ec2_tag" "eks_subnet_cluster_tag" {
  for_each    = toset(local.selected_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.resolved_cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "eks_subnet_elb_tag" {
  for_each    = toset(local.selected_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}
