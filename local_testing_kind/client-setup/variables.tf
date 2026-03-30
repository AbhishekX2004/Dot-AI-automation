# =============================================================================
# client-setup/variables.tf — Client Cluster Variables (kind / Local Development)
# =============================================================================
# This module is designed to be applied MULTIPLE TIMES using different .tfvars
# files — one per client cluster. DO NOT use for_each or count.
#
# Usage:
#   terraform init
#   terraform workspace new client-a          # isolate state per client
#   terraform apply -var-file=client-a.tfvars
#
# Example client-a.tfvars:
# --------------------------------------------------------------------------
#   client_id = "client-a"
# --------------------------------------------------------------------------
#
# Example client-b.tfvars:
# --------------------------------------------------------------------------
#   client_id = "client-b"
# --------------------------------------------------------------------------
# =============================================================================

variable "client_id" {
  description = <<-EOT
    Unique identifier for this client (lowercase letters, numbers, hyphens only).
    Drives the kind cluster name: "client-<client_id>"
    Also used by the onboard-client-kind.sh script as CLIENT_ID.
    Must be at least 2 characters (e.g. "client-a", "acme-corp").
  EOT
  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.client_id))
    error_message = "client_id must use only lowercase letters, numbers, and hyphens, and must start/end with an alphanumeric character (e.g. 'client-a', 'acme-corp')."
  }
}

variable "k8s_version" {
  description = <<-EOT
    Kubernetes node image version tag for kindest/node.
    Pinned to v1.35.0 to match the AWS EKS cloud environment and the Hub cluster.
    Verify the image exists before applying:
      docker pull kindest/node:v1.35.0
  EOT
  type    = string
  default = "v1.35.0"
}

variable "kubeconfig_output_path" {
  description = <<-EOT
    Local filesystem path where the client cluster's kubeconfig will be written.
    The onboard-client-kind.sh script reads this file to authenticate to the client cluster.
    Defaults to the current working directory. Can be overridden per-client.
  EOT
  type    = string
  default = "./client-kubeconfig.yaml"
}
