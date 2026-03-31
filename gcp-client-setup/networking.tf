# Use the default VPC and subnetwork to avoid additional custom network costs.
# The default network usually is ready out-of-the-box in most GCP projects.

data "google_compute_network" "default" {
  name = "default"
}

data "google_compute_subnetwork" "default" {
  name   = "default"
  region = var.gcp_region
}
