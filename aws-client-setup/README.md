# AWS Client Setup -- Terraform Module

Provisions an **Amazon EKS cluster** intended to be onboarded as a **client** to the Dot-AI Hub via the `onboard-client.sh` script. Uses the **AWS default VPC** to avoid custom networking costs. Designed to be fully isolated and self-contained.

> **Purpose:** This directory creates the client-side infrastructure. The Hub cluster is created separately in `eks-cluster/`.

---

## What Gets Created

| Resource | Details |
|---|---|
| **EKS Cluster** | Named `dot-ai-client-<client_name>`, public + private API endpoint |
| **Managed Node Group** | `t3.small` x 2 (min 1, max 4) |
| **IAM Roles** | Cluster role + Node role with required AWS policies |
| **OIDC Provider** | Enables IRSA (IAM Roles for Service Accounts) |
| **EKS Add-ons** | CoreDNS, kube-proxy, VPC CNI, EBS CSI driver |
| **Security Group** | Includes intra-VPC ingress on port 443 for Hub Controller access |
| **Networking** | Uses default VPC + default subnets (no NAT Gateway) |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- IAM permissions to create EKS, EC2, IAM, and VPC resources

---

## Quick Start

```bash
# 1. Enter the module directory
cd aws-client-setup/

# 2. Copy and customise variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars -- at minimum set client_name

# 3. Initialise providers
terraform init

# 4. Preview changes
terraform plan -out=tfplan

# 5. Apply
terraform apply tfplan

# 6. (Optional) Populate the cluster with demo workloads
chmod +x setup-client-workloads.sh
./setup-client-workloads.sh

# 7. View the onboarding values to copy into your client.vars file
terraform output
```

---

## End-to-End Onboarding Flow

```
1. terraform apply              (this directory)
   -- Provisions client EKS cluster on AWS

2. terraform output
   -- Shows CLOUD_PROVIDER, AWS_REGION, EKS_CLUSTER_NAME

3. cp ../client.vars.example acme-corp.vars
   -- Fill in the output values + Hub details

4. cd .. && ./onboard-client.sh acme-corp.vars
   -- Connects client cluster to the Hub
```

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
