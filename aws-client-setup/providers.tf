terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ---------------------------------------------------------------------------
# AWS Provider
# Region is driven by var.aws_region so all resources land in the same place.
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        ManagedBy   = "terraform"
        Project     = "dot-ai"
        Environment = var.environment
        Role        = "client"
        ClientName  = var.client_name
      },
      var.tags
    )
  }
}

# ---------------------------------------------------------------------------
# Kubernetes Provider
# Wired to the EKS cluster that Terraform will create in this module.
# The aws_eks_cluster_auth data source fetches a short-lived token.
# ---------------------------------------------------------------------------
data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
