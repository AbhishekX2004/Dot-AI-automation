# =============================================================================
# Default VPC & Subnets
#
# Using the AWS default VPC avoids NAT Gateway / custom VPC costs.
# The default VPC exists in every region and has a default subnet per AZ.
# =============================================================================

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

# Slice the list to respect var.azs_count (keep billing low by default).
locals {
  # Use only the first azs_count subnets.
  selected_subnet_ids = slice(
    tolist(data.aws_subnets.default.ids),
    0,
    min(var.azs_count, length(data.aws_subnets.default.ids))
  )
}

# ---------------------------------------------------------------------------
# EKS requires specific tags on the subnets it uses.
# We tag the *default* subnets in-place rather than creating new ones.
# ---------------------------------------------------------------------------
resource "aws_ec2_tag" "eks_subnet_cluster_tag" {
  for_each    = toset(local.selected_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "eks_subnet_elb_tag" {
  for_each    = toset(local.selected_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}
