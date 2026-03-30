# =============================================================================
# hub-setup/variables.tf — Hub Cluster Variables (kind / Local Development)
# =============================================================================
# Mirror of hub-eks-cluster/variables.tf but for a local kind cluster.
# Cloud-specific vars (aws_region, VPC, EC2 instance types) are removed.
# =============================================================================

variable "hub_cluster_name" {
  description = "Name of the Hub kind cluster. kubectl contexts will be prefixed with 'kind-' automatically."
  type        = string
  default     = "hub-cluster"
}

variable "k8s_version" {
  description = <<-EOT
    Kubernetes node image version tag for kindest/node.
    Pinned to v1.35.0 to match the AWS EKS cloud environment.
    Verify the image exists before applying:
      docker pull kindest/node:v1.35.0
    Browse available tags at: https://hub.docker.com/r/kindest/node/tags
  EOT
  type    = string
  default = "v1.35.0"
}

variable "host_http_port" {
  description = <<-EOT
    Host machine port mapped to the cluster node's container port 80 (HTTP Ingress).
    Change this if port 8080 is already in use on your machine.
    Access Ingress routes via: http://localhost:<host_http_port>
  EOT
  type    = number
  default = 8080
}

variable "host_https_port" {
  description = <<-EOT
    Host machine port mapped to the cluster node's container port 443 (HTTPS Ingress).
    Change this if port 8443 is already in use on your machine.
  EOT
  type    = number
  default = 8443
}

variable "metallb_version" {
  description = <<-EOT
    MetalLB release version to deploy to the Hub cluster.
    MetalLB simulates AWS NLB-backed LoadBalancer services in a local kind environment.
    Browse releases at: https://github.com/metallb/metallb/releases
  EOT
  type    = string
  default = "v0.14.5"
}

variable "metallb_ip_range" {
  description = <<-EOT
    IP address range (dash notation) for the MetalLB IPAddressPool.
    This MUST be a free, unused slice within the Docker 'kind' bridge network subnet.

    HOW TO DETECT YOUR SUBNET DYNAMICALLY (run after first cluster creation):
      docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' kind

    Example outputs and matching ranges:
      172.18.0.0/16  →  172.18.255.200-172.18.255.250  (default)
      172.19.0.0/16  →  172.19.255.200-172.19.255.250
      192.168.0.0/16 →  192.168.255.200-192.168.255.250

    NOTE: The 'kind' Docker network is created on the first 'kind create cluster'
    (i.e., the first 'terraform apply'). If this is a fresh machine, the default
    172.18.x.x range is correct in ~95% of Docker Desktop / Docker CE setups.
    Override in terraform.tfvars if your subnet differs.
  EOT
  type    = string
  default = "172.18.255.200-172.18.255.250"
}

variable "nginx_ingress_version" {
  description = <<-EOT
    NGINX Ingress Controller version tag.
    The kind-specific manifest is fetched from:
      https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-<version>/deploy/static/provider/kind/deploy.yaml
    The kind manifest pre-configures DaemonSet scheduling, nodeSelector (ingress-ready=true),
    and tolerations for the kind control-plane taint — no extra patches needed.
    Browse releases at: https://github.com/kubernetes/ingress-nginx/releases
  EOT
  type    = string
  default = "v1.10.1"
}
