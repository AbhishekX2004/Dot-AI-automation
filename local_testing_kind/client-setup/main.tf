# =============================================================================
# client-setup/main.tf — Client Cluster for Dot-AI (kind / Local Development)
# =============================================================================
# Replaces: aws-client-setup/{eks.tf, networking.tf, providers.tf}
#
# This module is deliberately lightweight — it creates only the kind cluster.
# No MetalLB, no Ingress. The client cluster is a pure Kubernetes API target;
# the Hub cluster owns all ingress and load-balancing responsibilities.
#
# USAGE (apply once per client, using isolated Terraform workspaces):
#   terraform init
#   terraform workspace new client-a
#   terraform apply -var-file=client-a.tfvars
#
#   terraform workspace new client-b
#   terraform apply -var-file=client-b.tfvars
#
# This creates kind clusters named: "client-a", "client-b", etc.
# kubectl contexts will be:         "kind-client-a", "kind-client-b", etc.
#
# After apply, the onboard script authenticates using the exported kubeconfig:
#   ./onboard-client-kind.sh client-a.vars
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "kind" {}

# =============================================================================
# Client Cluster
# =============================================================================
# Cluster name is derived from var.client_id: "client-<client_id>"
# This matches the naming convention used in the onboard script (CLIENT_CLUSTER_NAME).
# =============================================================================

resource "kind_cluster" "client" {
  # Naming convention: "client-<id>" e.g. "client-a", "client-acme-corp"
  # The kubectl context will be "kind-client-<id>" (kind prefixes with "kind-").
  name           = "client-${var.client_id}"
  node_image     = "kindest/node:${var.k8s_version}"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # Single control-plane node. No worker nodes needed for a lightweight
    # client cluster — the dot-ai workloads run on the Hub, not the client.
    node {
      role = "control-plane"
    }
  }
}

# =============================================================================
# Export Kubeconfig
# =============================================================================
# Write the client cluster's kubeconfig to a local file.
# The onboard-client-kind.sh script reads this file (TMP_KUBECONFIG) to
# authenticate all kubectl operations against the client cluster.
#
# NOTE: The tehcyx/kind provider also merges the cluster into ~/.kube/config
# automatically, making 'kubectl --context kind-client-<id>' work globally.
# The explicit export here provides a clean, isolated file for scripting.
# =============================================================================

resource "null_resource" "export_kubeconfig" {
  depends_on = [kind_cluster.client]

  triggers = {
    cluster_id             = kind_cluster.client.id
    kubeconfig_output_path = var.kubeconfig_output_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "→ Exporting kubeconfig for client cluster 'client-${var.client_id}'..."
      kind get kubeconfig --name "client-${var.client_id}" > "${var.kubeconfig_output_path}"
      chmod 600 "${var.kubeconfig_output_path}"
      echo "✓ Kubeconfig written to: ${var.kubeconfig_output_path}"
      echo ""
      echo "  kubectl context: kind-client-${var.client_id}"
      echo "  Cluster ready.  Next step:"
      echo "    cd ../ && ./onboard-client-kind.sh <client-id>.vars"
    EOT
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "cluster_name" {
  description = "Name of the created kind cluster."
  value       = kind_cluster.client.name
}

output "kubectl_context" {
  description = "kubectl context name for this client cluster (use with --context flag)."
  value       = "kind-${kind_cluster.client.name}"
}

output "kubeconfig_path" {
  description = "Path to the exported kubeconfig file for use in the onboard script."
  value       = var.kubeconfig_output_path
}

output "next_step" {
  description = "Command to run the onboarding script for this client."
  value       = "cd ../ && ./onboard-client-kind.sh <your-client-id>.vars"
}
