# Cluster Identity
output "cluster_name" {
  description = "Name of the client GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# Networking
output "network_id" {
  value = data.google_compute_network.default.id
}

output "subnetwork_id" {
  value = data.google_compute_subnetwork.default.id
}

# Onboarding Vars
output "onboard_cloud_provider" {
  description = "Value to use for CLOUD_PROVIDER in client.vars"
  value       = "gke"
}

output "onboard_gke_project" {
  description = "Value to use for GKE_PROJECT in client.vars"
  value       = var.gcp_project
}

output "onboard_gke_cluster_name" {
  description = "Value to use for GKE_CLUSTER_NAME in client.vars"
  value       = google_container_cluster.this.name
}

output "onboard_gke_zone" {
  description = "Value to use for GKE_ZONE in client.vars"
  value       = var.gcp_zone
}

output "kubeconfig_command" {
  description = "Run this command to update your local kubeconfig for this client cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --project ${var.gcp_project} --zone ${var.gcp_zone}"
}

output "onboard_client_vars_snippet" {
  description = "Ready-to-copy snippet for client.vars (GKE section)."
  value       = <<-EOT

    ┌──────────────────────────────────────────────────────────────────┐
    │  Copy the following into your client.vars file:                │
    ├──────────────────────────────────────────────────────────────────┤
    │                                                                  │
    │  CLOUD_PROVIDER=gke                                              │
    │  GKE_PROJECT=${var.gcp_project}
    │  GKE_CLUSTER_NAME=${google_container_cluster.this.name}
    │  GKE_ZONE=${var.gcp_zone}
    │                                                                  │
    └──────────────────────────────────────────────────────────────────┘
    Run ./setup-client-workloads.sh to add dummy workloads.
  EOT
}
