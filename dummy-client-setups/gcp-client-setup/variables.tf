variable "gcp_project" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone (for Zonal cluster to save costs)"
  type        = string
  default     = "us-central1-c"
}

variable "environment" {
  description = "Environment label applied to all resources (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "client_name" {
  description = "A short, unique name for this client (e.g. \"acme-corp\")."
  type        = string
  default     = "client-1"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.client_name))
    error_message = "client_name must be lowercase letters, numbers, and hyphens only."
  }
}

variable "cluster_name" {
  description = "Name for the client GKE cluster. Auto-generated if empty."
  type        = string
  default     = ""
}

variable "node_machine_type" {
  description = "GCE machine type for nodes"
  type        = string
  default     = "e2-micro"
}

variable "node_disk_size_gb" {
  description = "Disk size for worker nodes"
  type        = number
  default     = 20
}

variable "node_count" {
  description = "Number of nodes in the single zone"
  type        = number
  default     = 1
}

variable "spot" {
  description = "Use Spot VMs to dramatically reduce costs for test workloads"
  type        = bool
  default     = true
}
