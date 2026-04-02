#!/usr/bin/env bash
# =============================================================================
# setup-kind-workloads.sh — Populate Kind Client Clusters with Demo Resources
# =============================================================================
# Usage:
#   ./setup-kind-workloads.sh [--context CONTEXT_NAME]
#
# If no context is provided, it tries to detect Kind client clusters.
#
# What this script does:
#   1. Validates the Kind context
#   2. Creates demo namespaces (client-frontend, client-backend, chaos-testing)
#   3. Deploys sample workloads (nginx, redis, a deliberately broken app)
#   4. Waits for healthy deployments where applicable
#
# Prerequisites: kubectl, kind
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo ""; echo -e "${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# Parse Arguments
CONTEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    *)         error "Unknown flag: $1. Usage: $0 [--context CONTEXT_NAME]" ;;
  esac
done

# Auto-detect context if not provided
if [[ -z "$CONTEXT" ]]; then
  log "No --context provided, attempting to auto-detect Kind client clusters..."
  KIND_CLIENT_CONTEXTS=$(kubectl config get-contexts -o name | grep "kind-client-client-" || true)
  
  if [[ -n "$KIND_CLIENT_CONTEXTS" ]]; then
    echo -e "Available Kind client contexts:"
    echo "$KIND_CLIENT_CONTEXTS"
    echo ""
    # For simplicity, we'll ask the user to pick or use the first one if only one exists
    COUNT=$(echo "$KIND_CLIENT_CONTEXTS" | wc -l)
    if [[ "$COUNT" -eq 1 ]]; then
      CONTEXT="$KIND_CLIENT_CONTEXTS"
      log "Only one Kind client cluster found. Using: $CONTEXT"
    else
      error "Multiple Kind clusters found. Please specify one using --context."
    fi
  else
    error "Could not find any 'kind-client-client-' contexts. Please specify one explicitly."
  fi
fi

# Verify context connectivity
if ! kubectl config get-contexts "$CONTEXT" &>/dev/null; then
  error "Context '$CONTEXT' not found in kubectl config."
fi

log "Target Context: $CONTEXT"

# Create Namespaces
section "Creating Demo Namespaces on $CONTEXT"

for NS in client-frontend client-backend chaos-testing; do
  kubectl --context "$CONTEXT" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
  success "Namespace '$NS' ready."
done

# Deploy Workloads
section "Deploying Demo Workloads"

# client-frontend: nginx web app
log "Deploying NGINX to client-frontend..."
kubectl --context "$CONTEXT" create deployment client-web-app \
  --image=nginx:alpine \
  -n client-frontend \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -

# Expose as a ClusterIP service
kubectl --context "$CONTEXT" expose deployment client-web-app \
  --port=80 --target-port=80 \
  -n client-frontend \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
success "client-web-app deployed in client-frontend."

# client-backend: redis cache
log "Deploying Redis to client-backend..."
kubectl --context "$CONTEXT" create deployment client-redis-cache \
  --image=redis:alpine \
  -n client-backend \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
success "client-redis-cache deployed in client-backend."

# chaos-testing: a deliberately broken deployment
log "Deploying a broken app to chaos-testing (for Dot-AI to diagnose)..."
# We'll use a broken image tag to trigger ImagePullBackOff
kubectl --context "$CONTEXT" create deployment failing-api \
  --image=node:super-broken-tag-999 \
  -n chaos-testing \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
success "failing-api deployed in chaos-testing (will be in ImagePullBackOff — intentional)."

# Wait for Healthy Deployments
section "Waiting for Healthy Deployments"

log "Waiting for client-web-app..."
kubectl --context "$CONTEXT" wait --for=condition=available deployment/client-web-app \
  -n client-frontend --timeout=60s && success "client-web-app is healthy." \
  || warn "client-web-app did not become available in 60s."

log "Waiting for client-redis-cache..."
kubectl --context "$CONTEXT" wait --for=condition=available deployment/client-redis-cache \
  -n client-backend --timeout=60s && success "client-redis-cache is healthy." \
  || warn "client-redis-cache did not become available in 60s."

log "Skipping wait for failing-api (intentionally broken)."

# Summary
section "Client Workloads Setup Complete!"

echo ""
echo -e "  Context  : ${GREEN}${CONTEXT}${NC}"
echo ""
echo -e "  ${CYAN}Pods in demo namespaces:${NC}"
kubectl --context "$CONTEXT" get pods -n client-frontend -n client-backend -n chaos-testing
echo ""
echo -e "  ${CYAN}Next step:${NC} Check the Dot-AI Web UI to see the synced resources and diagnostic alerts."
echo ""
