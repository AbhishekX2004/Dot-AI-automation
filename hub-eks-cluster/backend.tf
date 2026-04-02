terraform {
  backend "s3" {
    bucket         = "multi-tenant-demo-03032026"  # <-- your S3 bucket name
    key            = "hub-eks-cluster/terraform.tfstate"
    region         = "us-east-1"                  # <-- must match aws_region
    encrypt        = true
    use_lockfile = true                           # <-- Enables S3-native locking
  }
}
