# EKS Hub Cluster -- Terraform Module

Provisions the **Hub EKS cluster** for the Dot-AI Hub-and-Spoke architecture. This cluster runs the Dot-AI AI agent, controller, web UI, and vector database. Each onboarded client gets a dedicated namespace on this cluster containing a scoped Helm release.

An NGINX Ingress Controller is deployed by default, backed by an AWS Network Load Balancer (NLB), to expose per-client Web UI and MCP API endpoints via host-based routing.

> **Note:** This module uses the AWS default VPC to avoid NAT Gateway costs. For production deployments, consider using a dedicated VPC with private subnets and a NAT Gateway.

---

## What Gets Created

| Resource | Details |
|---|---|
| **EKS Cluster** | Named `dot-ai-eks` (configurable), public + private API endpoint |
| **Managed Node Group** | `t3.small` x 2 nodes (min 1, max 4, configurable) |
| **IAM Roles** | Cluster role + Node role with required AWS policies |
| **OIDC Provider** | Enables IRSA (IAM Roles for Service Accounts) |
| **EKS Add-ons** | CoreDNS, kube-proxy, VPC CNI, EBS CSI driver |
| **NGINX Ingress** | Helm-deployed ingress controller with NLB |
| **Networking** | Default VPC + default subnets (no NAT Gateway) |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
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

# 6. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name dot-ai-eks

# 7. Verify
kubectl get nodes
```

---

## Post-Deployment: Retrieve the NLB IP

After provisioning, retrieve the NLB IP address. This IP is required when configuring the `BASE_DOMAIN` in `client.vars` for client onboarding.

```bash
# Get the NLB hostname
NLB_HOST=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Resolve to an IP (NLB may have multiple IPs; use any one)
dig +short "$NLB_HOST"

# The BASE_DOMAIN for client.vars will be: <IP>.nip.io
```

> **Important:** If you destroy and recreate this cluster, the NLB gets a new IP. You must update `BASE_DOMAIN` in all active client vars files and re-run `onboard-client.sh`.

---

## Onboarding Clients

Once the Hub is running, onboard client clusters using the `onboard-client.sh` script from the repository root. See the [root README](../README.md) for the complete workflow.

---

## Variables

| Name | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `environment` | `dev` | Environment label |
| `cluster_name` | `dot-ai-eks` | EKS cluster name |
| `cluster_version` | `1.35` | Kubernetes version |
| `azs_count` | `2` | Number of AZs to use (lower = cheaper) |
| `node_instance_type` | `t3.small` | EC2 instance type for nodes |
| `node_capacity_type` | `ON_DEMAND` | `ON_DEMAND` or `SPOT` |
| `node_desired_size` | `2` | Desired node count |
| `node_min_size` | `1` | Min nodes |
| `node_max_size` | `4` | Max nodes |
| `node_disk_size_gb` | `20` | EBS root volume size (GiB) |
| `enable_nginx_ingress` | `true` | Deploy the NGINX Ingress Controller |
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
| `oidc_provider_url` | OIDC issuer URL (without `https://`) |
| `kubeconfig_command` | Ready-to-run `aws eks update-kubeconfig` command |
| `nginx_ingress_command` | Command to retrieve the NLB hostname |
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

| Resource | Approximate Monthly Cost |
|---|---|
| EKS Control Plane | $73 |
| 2x `t3.small` (on-demand) | ~$30 |
| EBS (2x 20 GiB gp2) | ~$4 |
| Network Load Balancer | ~$16 |
| **Total** | **~$123/month** |

> Switch to `node_capacity_type = "SPOT"` to cut node costs by approximately 70%.

---

## Teardown

Before destroying the Hub cluster, remove all onboarded client Helm releases and namespaces first:

```bash
# For each onboarded client:
helm uninstall dot-ai-<CLIENT_ID> -n <CLIENT_ID>
kubectl delete namespace <CLIENT_ID>

# Then destroy the Terraform resources:
terraform destroy
```
