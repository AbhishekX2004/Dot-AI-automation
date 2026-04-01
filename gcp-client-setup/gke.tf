locals {
  resolved_cluster_name = var.cluster_name != "" ? var.cluster_name : "dot-ai-gcp-client-${var.client_name}"
}

# Isolated Least Privilege Service Account for GKE Nodes
resource "google_service_account" "gke_sa" {
  account_id   = "${local.resolved_cluster_name}-sa"
  display_name = "GKE Service Account for ${local.resolved_cluster_name}"
}

resource "google_project_iam_member" "gke_sa_log_writer" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_sa_metric_writer" {
  project = var.gcp_project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_sa_monitoring_viewer" {
  project = var.gcp_project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# Zonal GKE Cluster for Cost Savings
resource "google_container_cluster" "this" {
  name     = local.resolved_cluster_name
  location = var.gcp_zone

  network    = data.google_compute_network.default.self_link
  subnetwork = data.google_compute_subnetwork.default.self_link

  # Remove the default node pool to ensure we use our highly-customized, Spot/e2-micro pool.
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.gcp_project}.svc.id.goog"
  }
}

# Managed Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${local.resolved_cluster_name}-nodes"
  location   = var.gcp_zone
  cluster    = google_container_cluster.this.name
  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-standard"

    spot = var.spot

    service_account = google_service_account.gke_sa.email
    oauth_scopes    = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      environment = var.environment
      client      = var.client_name
    }
  }
}
