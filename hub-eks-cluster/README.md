# Dot-AI Hub Cluster (EKS)

This directory contains Terraform manifests to provision the **Hub EKS cluster**. This cluster serves as the "Brain" of the Dot-AI deployment, hosting the AI agent, the management controller, the Web UI, and the Qdrant vector database.

> [NOTE]
> Each managed **Client (Spoke)** cluster will have its own dedicated namespace and Helm release on this Hub cluster.

---

## Architecture Role

The Hub cluster is the central management plane. It uses:
- **NGINX Ingress:** To expose per-client dashboards and APIs via an AWS Network Load Balancer (NLB).
- **Controller Manager:** To watch and sync resources from remote client clusters.
- **Qdrant:** To store and query embeddings for AI-powered operations.

---

## What Gets Created

| Resource | Details |
|---|---|
| **EKS Cluster** | Name: `dot-ai-eks`, version 1.35 |
| **Managed Node Group** | 2x `t3.small` nodes (min 1, max 4) |
| **Ingress Controller** | NGINX Ingress with a public Network Load Balancer (NLB) |
| **Networking** | Uses AWS Default VPC (no NAT Gateway costs) |
| **Add-ons** | EBS CSI driver, VPC CNI, CoreDNS, kube-proxy |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- IAM permissions for EKS, EC2, VPC, and IAM.

---

## Quick Start

```bash
cd hub-eks-cluster/

# 1. Customise variables (optional)
cp terraform.tfvars.example terraform.tfvars

# 2. Provision Cluster
terraform init
terraform apply --auto-approve

# 3. Configure Local Access
aws eks update-kubeconfig --region us-east-1 --name dot-ai-eks
```

---

## Post-Deployment: Retrieve the NLB IP

Once the Hub is up, you need its public IP address to configure the `BASE_DOMAIN` for your clients.

```bash
# 1. Get the NLB hostname
NLB_HOST=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 2. Resolve to an IP
dig +short "$NLB_HOST" | head -n 1
```

The resulting IP will be used in your `client.vars` files as:
`BASE_DOMAIN=<NLB_IP>.nip.io`

> [!IMPORTANT]
> If you recreate this cluster, the NLB IP will change. You must update your `client.vars` and re-run the [onboarding script](../onboard-client.sh).

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
