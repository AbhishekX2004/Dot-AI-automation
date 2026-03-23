# AWS Client Setup (Spoke Cluster)

This directory contains Terraform manifests to provision an **Amazon EKS cluster** designed to act as a **Spoke (Client)** in the Dot-AI Hub-and-Spoke architecture. Once provisioned, it is onboarded to the Hub using the root `onboard-client.sh` script.

> [!IMPORTANT]
> This directory creates the client-side infrastructure. The **Hub** cluster (the "Brain") must be created separately in the [hub-eks-cluster/](../hub-eks-cluster/README.md) directory.

---

## Architecture Role

In a typical setup, you have:
1.  **One Hub Cluster:** Runs the Dot-AI agent, UI, and database.
2.  **Multiple Client Clusters:** Managed by the Hub. This module provisions one such cluster.

---

## What Gets Created

| Resource | Details |
|---|---|
| **EKS Cluster** | Name: `dot-ai-client-<client_name>`, version 1.35 |
| **Managed Node Group** | 2x `t3.small` nodes (min 1, max 4) |
| **Networking** | Uses AWS Default VPC (no NAT Gateway costs) |
| **Security Group** | Permits HTTPS (443) from VPC CIDR for Hub-to-Client communication |
| **Add-ons** | EBS CSI driver, VPC CNI, CoreDNS, kube-proxy |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- IAM permissions for EKS, EC2, VPC, and IAM.

---

## Quick Start

```bash
cd aws-client-setup/

# 1. Customise variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars -- set 'client_name' (e.g. "acme-corp")

# 2. Provision Cluster
terraform init
terraform apply --auto-approve

# 3. (Optional) Deploy Demo Workloads
./setup-client-workloads.sh
```

---

## Connecting to the Hub (Onboarding)

After the `terraform apply` finishes, follow these steps to connect this cluster to your Hub:

1.  **Get Onboarding Values:** Run `terraform output` to see the settings needed.
2.  **Create Vars File:** In the project root, create a file (e.g., `acme-corp.vars`) using [client.vars.example](../client.vars.example) as a template.
3.  **Run Onboarding:**
    ```bash
    cd ..
    ./onboard-client.sh acme-corp.vars
    ```

For a detailed breakdown of what happens during onboarding, see the [Onboard Client Script Breakdown](../docs/onboard-client-script-breakdown.md).

---

## Cross-Cluster Networking

When the Hub and Client clusters share the same AWS VPC (which they do by default since both use the default VPC), the Hub Controller resolves the Client API server to private IP addresses. To allow this traffic, the Security Group for this module includes an ingress rule that permits HTTPS (port 443) from the VPC CIDR block.

If you provision client clusters outside of this Terraform module, you must manually add an equivalent ingress rule to the cluster's Security Group:

```
Type: HTTPS
Port: 443
Source: <VPC CIDR block, e.g. 172.31.0.0/16>
```

Without this rule, the Hub Controller will time out when attempting to connect to the Client API server.

---

## Variables

| Name | Default | Description |
|---|---|---|
| `client_name` | `client-1` | Unique client identifier (lowercase, hyphens) |
| `aws_region` | `us-east-1` | AWS region |
| `environment` | `dev` | Environment label |
| `cluster_name` | *(auto)* | EKS cluster name (auto: `dot-ai-client-<client_name>`) |
| `cluster_version` | `1.35` | Kubernetes version |
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
| `cluster_name` | Client EKS cluster name |
| `cluster_endpoint` | API server URL |
| `cluster_ca_certificate` | Base64 CA cert (sensitive) |
| `oidc_provider_arn` | OIDC provider ARN for IRSA |
| `kubeconfig_command` | Ready-to-run `aws eks update-kubeconfig` command |
| `onboard_cloud_provider` | Value for `CLOUD_PROVIDER` in client.vars |
| `onboard_aws_region` | Value for `AWS_REGION` in client.vars |
| `onboard_eks_cluster_name` | Value for `EKS_CLUSTER_NAME` in client.vars |
| `onboard_client_vars_snippet` | Ready-to-copy snippet for client.vars |

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
| **Total** | **~$107/month** |

> Switch to `node_capacity_type = "SPOT"` to cut node costs by approximately 70%.

---

## Teardown

```bash
# Remove demo workloads first (if created)
kubectl delete namespace client-frontend client-backend chaos-testing --ignore-not-found

# Remove the Dot-AI onboarding resources from the client cluster
kubectl delete namespace dot-ai <CLIENT_ID> --ignore-not-found
kubectl delete clusterrolebinding dot-ai-remote-admin-binding --ignore-not-found

# Destroy all Terraform-managed resources
terraform destroy
```
