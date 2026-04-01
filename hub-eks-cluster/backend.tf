# =============================================================================
# Terraform State Backend
#
# By default this module uses LOCAL state (no backend block = local).
# To enable remote state in S3, uncomment the block below, fill in the
# bucket / key / region, and run `terraform init -reconfigure`.
# =============================================================================

terraform {
  backend "s3" {
    bucket         = "multi-tenant-demo-03032026"  # <-- your S3 bucket name
    key            = "hub-eks-cluster/terraform.tfstate"
    region         = "us-east-1"                  # <-- must match aws_region
    encrypt        = true
    use_lockfile = true                           # <-- Enables S3-native locking
  }
}
