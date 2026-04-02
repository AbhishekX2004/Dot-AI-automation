# Cluster Identity
output "cluster_name" {
  description = "Name of the client AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource Group where the AKS cluster is deployed"
  value       = azurerm_resource_group.rg.name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = azurerm_kubernetes_cluster.this.kube_config.0.host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate
  sensitive   = true
}

# Onboarding Vars
output "onboard_cloud_provider" {
  description = "Value to use for CLOUD_PROVIDER in client.vars"
  value       = "aks"
}

output "onboard_aks_subscription_id" {
  description = "Value to use for AKS_SUBSCRIPTION_ID in client.vars"
  value       = var.az_subscription_id
}

output "onboard_aks_resource_group" {
  description = "Value to use for AKS_RESOURCE_GROUP in client.vars"
  value       = azurerm_resource_group.rg.name
}

output "onboard_aks_cluster_name" {
  description = "Value to use for AKS_CLUSTER_NAME in client.vars"
  value       = azurerm_kubernetes_cluster.this.name
}

output "kubeconfig_command" {
  description = "Run this command to update your local kubeconfig for this client cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.this.name}"
}

output "onboard_client_vars_snippet" {
  description = "Ready-to-copy snippet for client.vars (AKS section)."
  value       = <<-EOT

    ┌──────────────────────────────────────────────────────────────────┐
    │  Copy the following into your client.vars file:                │
    ├──────────────────────────────────────────────────────────────────┤
    │                                                                  │
    │  CLOUD_PROVIDER=aks                                              │
    │  AKS_SUBSCRIPTION_ID=${var.az_subscription_id != null ? var.az_subscription_id : "your-subscription-id"}
    │  AKS_RESOURCE_GROUP=${azurerm_resource_group.rg.name}
    │  AKS_CLUSTER_NAME=${azurerm_kubernetes_cluster.this.name}
    │                                                                  │
    └──────────────────────────────────────────────────────────────────┘
    Run ./setup-client-workloads.sh to add dummy workloads.
  EOT
}
