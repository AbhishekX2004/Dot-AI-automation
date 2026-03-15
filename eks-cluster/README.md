# EKS Cluster — Standalone Terraform Module

Provisions a production-ready **Amazon EKS cluster** using the **AWS default VPC** (no custom networking costs). Designed to be fully isolated and self-contained, with no shared state with other parts of this repository.

> **Future use:** This cluster will host virtual clusters separated by Kubernetes namespaces.

---

## What Gets Created

| Resource | Details |
|---|---|
| **EKS Cluster** | K8s 1.32, public + private API endpoint |
| **Managed Node Group** | `t3.small` × 2 (min 1, max 4) |
| **IAM Roles** | Cluster role + Node role with required AWS policies |
| **OIDC Provider** | Enables IRSA (IAM Roles for Service Accounts) |
| **EKS Add-ons** | CoreDNS, kube-proxy, VPC CNI, EBS CSI driver |
| **Networking** | Uses default VPC + default subnets (no NAT Gateway) |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- IAM permissions to create EKS, EC2, IAM, and VPC resources

---

## Quick Start

```bash
# 1. Enter the module directory
cd eks-cluster/

# 2. Copy and customise variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Initialise providers
terraform init

# 4. Preview changes
terraform plan -out=tfplan

# 5. Apply
terraform apply tfplan

# 6. Configure kubectl (command is also printed as an output)
aws eks update-kubeconfig --region us-east-1 --name dot-ai-eks

# 7. Verify
kubectl get nodes
```

---

## Variables

| Name | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `environment` | `dev` | Environment label |
| `cluster_name` | `dot-ai-eks` | EKS cluster name |
| `cluster_version` | `1.32` | Kubernetes version |
| `azs_count` | `2` | Number of AZs to use (lower = cheaper) |
| `node_instance_type` | `t3.small` | EC2 instance type for nodes |
| `node_capacity_type` | `ON_DEMAND` | `ON_DEMAND` or `SPOT` |
| `node_desired_size` | `2` | Desired node count |
| `node_min_size` | `1` | Min nodes |
| `node_max_size` | `4` | Max nodes |
| `node_disk_size_gb` | `20` | EBS root volume size (GiB) |
| `enable_ebs_csi_driver` | `true` | Install EBS CSI add-on |
| `tags` | `{}` | Extra resource tags |

---

## Outputs

| Output | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server URL |
| `cluster_ca_certificate` | Base64 CA cert (sensitive) |
| `oidc_provider_arn` | OIDC provider ARN for IRSA |
| `oidc_provider_url` | OIDC issuer URL (no `https://`) |
| `kubeconfig_command` | Ready-to-run `aws eks update-kubeconfig` command |
| `node_group_arn` | ARN of the managed node group |
| `vpc_id` | VPC ID used by the cluster |
| `subnet_ids` | Subnet IDs selected for the cluster |

---

## Enabling Remote State

Edit `backend.tf` and uncomment the `terraform { backend "s3" { ... } }` block, then run:

```bash
terraform init -reconfigure
```

---

## Cost Estimate (us-east-1, default config)

| Resource | ~Monthly Cost |
|---|---|
| EKS Control Plane | $73 |
| 2× `t3.small` (on-demand) | ~$30 |
| EBS (2× 20 GiB gp2) | ~$4 |
| **Total** | **~$107/month** |

> **Tip:** Switch to `node_capacity_type = "SPOT"` to cut node costs by ~70%.

---

## Teardown

```bash
terraform destroy
```
