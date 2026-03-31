# =============================================================================
# hub-setup/main.tf — Hub Cluster for Dot-AI (kind / Local Development)
# =============================================================================
# Replaces: hub-eks-cluster/{eks.tf, ingress.tf, networking.tf, providers.tf}
#
# What this module does:
#   1. Provisions a 'hub-cluster' kind cluster with Ingress extraPortMappings
#   2. Installs MetalLB to simulate AWS NLB LoadBalancer services
#   3. Configures MetalLB with an IPAddressPool from the kind Docker subnet
#   4. Deploys the NGINX Ingress Controller (kind-optimised manifest)
#
# Why null_resource instead of the kubernetes/helm providers for addon installs?
#   The kubernetes and helm Terraform providers require the cluster API endpoint
#   at PLAN time. A brand-new kind cluster does not exist yet during planning,
#   causing an unresolvable chicken-and-egg bootstrap failure. Using null_resource
#   + local-exec (kubectl) sidesteps this because the local-exec command only
#   runs AFTER the kind_cluster resource has been confirmed created.
#
# IMPORTANT — Shell variable escaping in local-exec commands:
#   Terraform processes ${...} interpolation in all strings BEFORE the shell runs.
#   Shell variables must use $VAR (no curly braces) to avoid Terraform treating
#   them as template expressions. Shell command substitution $(...) is also safe.
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
  }
}

provider "kind" {}

# =============================================================================
# Hub Cluster
# =============================================================================

resource "kind_cluster" "hub" {
  name           = var.hub_cluster_name
  node_image     = "kindest/node:${var.k8s_version}"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # Control-plane node — also serves as a worker in single-node kind clusters.
    # extraPortMappings forward host ports to container ports so the NGINX Ingress
    # Controller can be reached directly from the host machine.
    node {
      role = "control-plane"

      # Map host:8080 → container:80   (HTTP Ingress)
      extra_port_mappings {
        container_port = 80
        host_port      = var.host_http_port
        protocol       = "TCP"
      }

      # Map host:8443 → container:443  (HTTPS Ingress)
      extra_port_mappings {
        container_port = 443
        host_port      = var.host_https_port
        protocol       = "TCP"
      }

      # Label the node 'ingress-ready=true' so the kind-specific NGINX Ingress
      # manifest (which uses a DaemonSet + nodeSelector) can schedule onto it.
      kubeadm_config_patches = [
        <<-YAML
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        YAML
      ]
    }
  }
}

# =============================================================================
# MetalLB — Step 1: Install CRDs + Controller
# =============================================================================
# MetalLB is a bare-metal load balancer implementation. In a kind environment
# it replaces AWS NLBs by assigning actual IPs (from the Docker bridge subnet)
# to Kubernetes Services of type LoadBalancer.
#
# The trigger on 'cluster_id' ensures this provisioner re-runs if the cluster
# is destroyed and recreated (e.g. after 'terraform destroy && terraform apply').
# =============================================================================

resource "null_resource" "metallb_install" {
  depends_on = [kind_cluster.hub]

  triggers = {
    cluster_id      = kind_cluster.hub.id
    metallb_version = var.metallb_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      echo "→ Exporting Hub kubeconfig..."
      KUBECONFIG_FILE=$(mktemp /tmp/hub-kubeconfig-XXXXXX)
      kind get kubeconfig --name "${var.hub_cluster_name}" > $KUBECONFIG_FILE

      echo "→ Installing MetalLB ${var.metallb_version} (CRDs + controller)..."
      kubectl --kubeconfig $KUBECONFIG_FILE apply \
        -f "https://raw.githubusercontent.com/metallb/metallb/${var.metallb_version}/config/manifests/metallb-native.yaml"

      echo "→ Waiting for MetalLB controller to reach Ready state (up to 120s)..."
      kubectl --kubeconfig $KUBECONFIG_FILE \
        wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=component=controller \
        --timeout=120s

      rm -f $KUBECONFIG_FILE
      echo "✓ MetalLB ${var.metallb_version} installed successfully."
    EOT
  }
}

# =============================================================================
# MetalLB — Step 2: Configure IPAddressPool + L2Advertisement
# =============================================================================
# These CRDs MUST be applied AFTER the MetalLB validating webhook server is
# healthy. The webhook validates IPAddressPool resources; if it is not yet
# running, the apply will be rejected with a "connection refused" error.
#
# Dynamic subnet detection (run on your host machine to verify):
#   docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' kind
#
# The IPAddressPool range (var.metallb_ip_range) is injected by Terraform
# interpolation into the inline YAML before the shell script executes.
# See metallb-config.yaml for a standalone reference copy with full comments.
# =============================================================================

resource "null_resource" "metallb_config" {
  depends_on = [null_resource.metallb_install]

  triggers = {
    cluster_id = kind_cluster.hub.id
    ip_range   = var.metallb_ip_range
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp /tmp/hub-kubeconfig-XXXXXX)
      kind get kubeconfig --name "${var.hub_cluster_name}" > $KUBECONFIG_FILE

      echo "→ Waiting for MetalLB webhook server to be ready (up to 180s)..."
      kubectl --kubeconfig $KUBECONFIG_FILE \
        wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=component=controller \
        --timeout=180s

      # Additional grace period: the webhook server registers ~5-10s after the
      # pod becomes Ready. Without this sleep, CRD applies may still be rejected.
      echo "→ Allowing 15s for the MetalLB webhook to fully register..."
      sleep 15

      echo "→ Applying MetalLB IPAddressPool (${var.metallb_ip_range}) and L2Advertisement..."
      kubectl --kubeconfig $KUBECONFIG_FILE apply -f - <<'METALCONFIG'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${var.metallb_ip_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2advert
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
METALCONFIG

      rm -f $KUBECONFIG_FILE
      echo "✓ MetalLB configured with IP range: ${var.metallb_ip_range}"
    EOT
  }
}

# =============================================================================
# NGINX Ingress Controller
# =============================================================================
# Replaces: hub-eks-cluster/ingress.tf (which used an AWS NLB annotation).
#
# The kind-specific NGINX manifest (provider/kind/deploy.yaml) differs from
# the standard manifest in three important ways:
#   1. Uses a DaemonSet instead of Deployment for reliable single-node scheduling
#   2. Pre-configures nodeSelector: { ingress-ready: "true" }
#   3. Pre-configures tolerations for the kind control-plane NoSchedule taint
#
# MetalLB will assign a LoadBalancer IP to the ingress-nginx-controller Service.
# The onboard script reads this IP to build nip.io hostnames for the Helm chart.
# =============================================================================

resource "null_resource" "nginx_ingress" {
  depends_on = [null_resource.metallb_config]

  triggers = {
    cluster_id            = kind_cluster.hub.id
    nginx_ingress_version = var.nginx_ingress_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp /tmp/hub-kubeconfig-XXXXXX)
      kind get kubeconfig --name "${var.hub_cluster_name}" > $KUBECONFIG_FILE

      echo "→ Installing NGINX Ingress Controller ${var.nginx_ingress_version} (kind manifest)..."
      kubectl --kubeconfig $KUBECONFIG_FILE apply \
        -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${var.nginx_ingress_version}/deploy/static/provider/kind/deploy.yaml"

      echo "→ Patching NGINX service to use MetalLB (changing NodePort to LoadBalancer)..."
      kubectl --kubeconfig $KUBECONFIG_FILE patch svc ingress-nginx-controller \
        -n ingress-nginx \
        -p '{"spec": {"type": "LoadBalancer"}}'

      echo "→ Waiting for NGINX Ingress pods to be Ready (up to 180s)..."
      kubectl --kubeconfig $KUBECONFIG_FILE \
        wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=180s

      echo "→ Verifying MetalLB assigned an External-IP to ingress-nginx-controller..."
      # Poll until External-IP is no longer '<pending>'
      for i in $(seq 1 30); do
        EXT_IP=$(kubectl --kubeconfig $KUBECONFIG_FILE \
          get svc ingress-nginx-controller -n ingress-nginx \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$EXT_IP" ]]; then
          echo "✓ NGINX Ingress LoadBalancer IP: $EXT_IP"
          break
        fi
        echo "  Waiting for LoadBalancer IP... ($i/30)"
        sleep 5
      done

      rm -f $KUBECONFIG_FILE
      echo "✓ NGINX Ingress Controller ${var.nginx_ingress_version} installed."
    EOT
  }
}
