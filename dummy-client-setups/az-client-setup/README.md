# Azure Client Setup

This module provisions a lightweight, cost-optimized client cluster on Azure Kubernetes Service (AKS) for the Hub-and-Spoke architecture. By default, it uses a Free Tier control plane and inexpensive Burst VMs (`Standard_B2s`) with simple `kubenet` networking.

## Quickstart

1. Create a `terraform.tfvars` file (use `terraform.tfvars.example` as a template).
2. Run Terraform logic to spin up the cluster:
   ```bash
   terraform init
   terraform apply
   ```
3. Copy the output snippet into a client `.vars` file (e.g. `client-a.vars`).
4. Run `./setup-client-workloads.sh` to inject dummy web apps/broken workloads into your test cluster.
5. In the root, run `../onboard-client.sh client-a.vars`.
