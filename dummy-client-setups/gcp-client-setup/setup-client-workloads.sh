#!/usr/bin/env bash
# =============================================================================
# setup-client-workloads.sh — Populate a Client GKE Cluster with Demo Resources
# =============================================================================
# Usage:
#   ./setup-client-workloads.sh [--cluster-name NAME] [--project PROJECT] [--zone ZONE]
#
# If flags are omitted, the script reads values from Terraform output in the
# current directory (requires `terraform output` to work).
#
# What this script does:
#   1. Updates kubeconfig for the client GKE cluster
#   2. Creates demo namespaces (client-frontend, client-backend, chaos-testing)
#   3. Deploys sample workloads (nginx, redis, a deliberately broken app)
#   4. Waits for healthy deployments and prints status
#
# Prerequisites: gcloud CLI, kubectl, terraform
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo ""; echo -e "${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# Parse Arguments
CLUSTER_NAME=""
GCP_PROJECT=""
GCP_ZONE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --project)      GCP_PROJECT="$2"; shift 2 ;;
    --zone)         GCP_ZONE="$2"; shift 2 ;;
    *)              error "Unknown flag: $1. Usage: $0 [--cluster-name NAME] [--project PROJECT] [--zone ZONE]" ;;
  esac
done

# Fall back to Terraform outputs if flags not provided.
if [[ -z "$CLUSTER_NAME" ]]; then
  log "No --cluster-name provided, reading from terraform output..."
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null) \
    || error "Could not read cluster_name from terraform output. Pass --cluster-name explicitly."
fi

if [[ -z "$GCP_PROJECT" ]]; then
  log "No --project provided, reading from terraform output..."
  GCP_PROJECT=$(terraform output -raw onboard_gke_project 2>/dev/null) \
    || error "Could not read onboard_gke_project from terraform output. Pass --project explicitly."
fi

if [[ -z "$GCP_ZONE" ]]; then
  log "No --zone provided, reading from terraform output..."
  GCP_ZONE=$(terraform output -raw onboard_gke_zone 2>/dev/null) \
    || error "Could not read onboard_gke_zone from terraform output. Pass --zone explicitly."
fi

log "Cluster : $CLUSTER_NAME"
log "Project : $GCP_PROJECT"
log "Zone    : $GCP_ZONE"

section "Updating kubeconfig for $CLUSTER_NAME"

gcloud container clusters get-credentials "$CLUSTER_NAME" --project "$GCP_PROJECT" --zone "$GCP_ZONE"
success "kubeconfig updated."

# Get the context name that was just set
CLIENT_CONTEXT=$(kubectl config current-context)
log "Using context: $CLIENT_CONTEXT"

# Create Namespaces
section "Creating Demo Namespaces"

for NS in client-frontend client-backend chaos-testing; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  success "Namespace '$NS' ready."
done

# Deploy Workloads
section "Deploying Demo Workloads"

# client-frontend: nginx web app
log "Deploying NGINX to client-frontend..."
kubectl create deployment client-web-app \
  --image=nginx:alpine \
  -n client-frontend \
  --dry-run=client -o yaml | kubectl apply -f -

# Expose as a ClusterIP service
kubectl expose deployment client-web-app \
  --port=80 --target-port=80 \
  -n client-frontend \
  --dry-run=client -o yaml | kubectl apply -f -
success "client-web-app deployed in client-frontend."

# client-backend: redis cache
log "Deploying Redis to client-backend..."
kubectl create deployment client-redis-cache \
  --image=redis:alpine \
  -n client-backend \
  --dry-run=client -o yaml | kubectl apply -f -
success "client-redis-cache deployed in client-backend."

# chaos-testing: a deliberately broken deployment
log "Deploying a broken app to chaos-testing (for Dot-AI to diagnose)..."
kubectl create deployment failing-api \
  --image=node:super-broken-tag-999 \
  -n chaos-testing \
  --dry-run=client -o yaml | kubectl apply -f -
success "failing-api deployed in chaos-testing (will be in ImagePullBackOff — intentional)."

# Wait for Healthy Deployments
section "Waiting for Healthy Deployments"

log "Waiting for client-web-app..."
kubectl wait --for=condition=available deployment/client-web-app \
  -n client-frontend --timeout=120s && success "client-web-app is healthy." \
  || warn "client-web-app did not become available in 120s."

log "Waiting for client-redis-cache..."
kubectl wait --for=condition=available deployment/client-redis-cache \
  -n client-backend --timeout=120s && success "client-redis-cache is healthy." \
  || warn "client-redis-cache did not become available in 120s."

log "Skipping wait for failing-api (intentionally broken)."

# Summary
section "Client Cluster Ready!"

echo ""
echo -e "  Cluster  : ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  Project  : ${GREEN}${GCP_PROJECT}${NC}"
echo -e "  Zone     : ${GREEN}${GCP_ZONE}${NC}"
echo -e "  Context  : ${GREEN}${CLIENT_CONTEXT}${NC}"
echo ""
echo -e "  ${CYAN}Pods across demo namespaces:${NC}"
kubectl get pods -n client-frontend -n client-backend -n chaos-testing 2>/dev/null \
  || kubectl get pods -A | grep -E "client-frontend|client-backend|chaos-testing"
echo ""
echo -e "  ${CYAN}Next step:${NC} Onboard this cluster to the Hub:"
echo -e "  ${GREEN}../onboard-client.sh <your-client>.vars${NC}"
echo ""
