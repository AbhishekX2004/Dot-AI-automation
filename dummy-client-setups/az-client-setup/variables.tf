variable "az_subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  default     = null
}

variable "az_location" {
  description = "Azure Location/Region for resources"
  type        = string
  default     = "denmarkeast"
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
  description = "Name for the client AKS cluster. Auto-generated if empty."
  type        = string
  default     = ""
}

variable "node_vm_size" {
  description = "Azure VM size for nodes. Using a very cheap one by default."
  type        = string
  default     = "Standard_B2s"
}

variable "node_disk_size_gb" {
  description = "Disk size for worker nodes"
  type        = number
  default     = 30
}

variable "node_count" {
  description = "Number of nodes in the system node pool"
  type        = number
  default     = 1
}
