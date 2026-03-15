# =============================================================================
# Terraform State Backend
#
# By default this module uses LOCAL state (no backend block = local).
# To enable remote state in S3, uncomment the block below, fill in the
# bucket / key / region, and run `terraform init -reconfigure`.
#
# Tip: create the S3 bucket and DynamoDB lock table with the
# `aws_s3_bucket` + `aws_dynamodb_table` resources BEFORE enabling this.
# =============================================================================

# terraform {
#   backend "s3" {
#     bucket         = "my-terraform-state-bucket"  # <-- your S3 bucket name
#     key            = "dot-ai/eks-cluster/terraform.tfstate"
#     region         = "us-east-1"                  # <-- must match aws_region
#     encrypt        = true
#     dynamodb_table = "terraform-lock"             # <-- DynamoDB table for locking
#   }
# }
