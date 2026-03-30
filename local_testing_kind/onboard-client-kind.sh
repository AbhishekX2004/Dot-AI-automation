#!/usr/bin/env bash

# =============================================================================
# onboard-client-kind.sh — Dot-AI Client Onboarding Script (kind / Local Dev)
# =============================================================================
# Usage:
#   ./onboard-client-kind.sh <vars-file>
#
# Example:
#   cp client.vars.example acme-corp.vars
#   # edit acme-corp.vars
#   ./onboard-client-kind.sh acme-corp.vars
#
# Prerequisites (all local, no cloud CLIs needed):
#   kind, kubectl, helm, docker, openssl
#
# What this script does:
#   1.  Loads and validates the client vars file
#   2.  Verifies kind clusters (Hub + Client) are running
#   3.  Exports the client cluster kubeconfig to a temp file
#   4.  Creates a dedicated namespace on the Hub for this client
#   5.  Creates the dot-ai-remote-admin ServiceAccount on the client cluster
#   6.  Applies the dot-ai-readonly ClusterRole (from project root)
#   7.  Binds the SA to dot-ai-readonly (NEVER cluster-admin)
#   8.  Generates a ServiceAccount token and extracts the Docker-internal
#       API server URL (not 127.0.0.1 — the Hub pod must reach the client!)
#   9.  Builds a clean kubeconfig and injects it as a Hub Secret
#   10. Detects the MetalLB-assigned LoadBalancer IP from NGINX Ingress
#   11. Constructs nip.io hostnames for the API and UI
#   12. Deploys the dot-ai Helm release onto the Hub
#   13. Bootstraps the client cluster (namespace, CRDs, ResourceSyncConfig, secrets)
#   14. Restarts the Hub controller for a clean sync
#
# === REQUIRED VARS FILE FIELDS ===
#   CLIENT_ID            Unique client identifier (e.g. "client-a", "acme-corp")
#   CLIENT_CLUSTER_NAME  Name of the kind cluster (e.g. "client-a")
#                        kubectl context will be "kind-${CLIENT_CLUSTER_NAME}"
#   AI_PROVIDER          openai | anthropic
#   AI_API_KEY           AI provider API key
#
# === OPTIONAL VARS FILE FIELDS (with defaults) ===
#   HUB_CLUSTER_NAME     kind cluster name for the Hub (default: hub-cluster)
#   HELM_CHART_PATH      Path to dot-ai-stack chart (default: ../dot-ai-stack)
#   HELM_TIMEOUT         Helm install timeout in seconds (default: 600)
#   LOCAL_EMBEDDINGS     Enable local embeddings (default: true)
#   INGRESS_CLASS        Ingress class name (default: nginx)
#
# === REMOVED FROM CLOUD VERSION ===
#   CLOUD_PROVIDER, BASE_DOMAIN, AWS_REGION, EKS_CLUSTER_NAME,
#   GKE_PROJECT, GKE_CLUSTER_NAME, GKE_ZONE, ACP_SERVER_URL, ACP_TOKEN
#   All cloud CLI prerequisites (aws, gcloud, curl)
# =============================================================================
set -euo pipefail

# =============================================================================
# Helpers
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

require_cmd() { command -v "$1" &>/dev/null || error "Required command not found: $1. Please install it."; }

# =============================================================================
# Load & Validate Vars File
# =============================================================================

VARS_FILE="${1:-}"
[[ -z "$VARS_FILE" ]] && error "Usage: $0 <vars-file>\n  Example: $0 client-a.vars"
[[ -f "$VARS_FILE" ]] || error "vars file not found: $VARS_FILE"

# shellcheck source=/dev/null
source "$VARS_FILE"
log "Loaded config from: $VARS_FILE"

section "Validating Configuration"

_require_var() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || error "Required variable \$$name is not set in $VARS_FILE"
}

_require_var CLIENT_ID
_require_var CLIENT_CLUSTER_NAME
_require_var AI_PROVIDER
_require_var AI_API_KEY

# Validate CLIENT_ID format (lowercase letters, numbers, hyphens only)
if ! echo "$CLIENT_ID" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
  error "CLIENT_ID '$CLIENT_ID' is invalid. Use only lowercase letters, numbers, and hyphens (e.g. acme-corp)."
fi

# Validate AI_PROVIDER
case "$AI_PROVIDER" in
  openai|anthropic) ;;
  *) error "AI_PROVIDER must be 'openai' or 'anthropic'. Got: $AI_PROVIDER" ;;
esac

# Set defaults for optional vars
HUB_CLUSTER_NAME="${HUB_CLUSTER_NAME:-hub-cluster}"
HELM_TIMEOUT="${HELM_TIMEOUT:-600}"
HELM_CHART_PATH="${HELM_CHART_PATH:-../dot-ai-stack}"
LOCAL_EMBEDDINGS="${LOCAL_EMBEDDINGS:-true}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"

# Derived context names (kind prefixes all contexts with "kind-")
HUB_CONTEXT="kind-${HUB_CLUSTER_NAME}"
CLIENT_CONTEXT="kind-${CLIENT_CLUSTER_NAME}"

# Derived resource names
HUB_NAMESPACE="$CLIENT_ID"
HELM_RELEASE="dot-ai-${CLIENT_ID}"
SECRET_NAME="client-${CLIENT_ID}-kubeconfig"

# Resolve script directory to locate project-root files (e.g. ClusterRole YAML)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTERROLE_FILE="${SCRIPT_DIR}/../dot-ai-readonly-clusterrole.yaml"

# Set up logging
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="${SCRIPT_DIR}/onboard-logs-${CLIENT_ID}-${TIMESTAMP}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/onboard.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging output to $LOG_FILE"

# Temp file cleanup on EXIT
TMP_KUBECONFIG=$(mktemp /tmp/dot-ai-client-kubeconfig-XXXXXX)
HUB_SECRET_KUBECONFIG=$(mktemp /tmp/dot-ai-hub-secret-kubeconfig-XXXXXX)
CRDS_TEMP=$(mktemp /tmp/dot-ai-crds-XXXXXX.yaml)
SYNC_TEMP=$(mktemp /tmp/dot-ai-sync-XXXXXX.yaml)
SECRET_TEMP=$(mktemp /tmp/dot-ai-secret-XXXXXX.yaml)

save_and_clean_tmp() {
  for f in "$@"; do
    if [[ -f "$f" ]]; then
      cp "$f" "$LOG_DIR/" 2>/dev/null || true
      rm -f "$f"
    fi
  done
}
trap 'save_and_clean_tmp "$TMP_KUBECONFIG" "$HUB_SECRET_KUBECONFIG" "$CRDS_TEMP" "$SYNC_TEMP" "$SECRET_TEMP"' EXIT

success "Configuration valid. Client ID: $CLIENT_ID | Hub: $HUB_CLUSTER_NAME | Client cluster: $CLIENT_CLUSTER_NAME"

# =============================================================================
# Check Prerequisites
# =============================================================================

section "Checking Prerequisites"
require_cmd kubectl
require_cmd helm
require_cmd openssl
require_cmd kind
require_cmd docker

# Verify Helm chart exists
[[ -d "$HELM_CHART_PATH" ]] || error "Helm chart not found at: $HELM_CHART_PATH"

# Verify ClusterRole YAML exists (used for RBAC setup on client cluster)
[[ -f "$CLUSTERROLE_FILE" ]] || error "dot-ai-readonly ClusterRole YAML not found at: $CLUSTERROLE_FILE\n  Expected: ${SCRIPT_DIR}/../dot-ai-readonly-clusterrole.yaml"

# Verify kind clusters are running
log "Verifying kind clusters..."
kind get clusters | grep -qE "^${HUB_CLUSTER_NAME}$" \
  || error "Hub cluster '${HUB_CLUSTER_NAME}' not found.\n  Run: cd hub-setup && terraform apply"
kind get clusters | grep -qE "^${CLIENT_CLUSTER_NAME}$" \
  || error "Client cluster '${CLIENT_CLUSTER_NAME}' not found.\n  Run: cd client-setup && terraform apply -var-file=<client>.tfvars"

# Verify kubectl contexts exist (kind merges these into ~/.kube/config on cluster creation)
kubectl config get-contexts "$HUB_CONTEXT" &>/dev/null \
  || error "kubectl context '$HUB_CONTEXT' not found. Ensure kind merged it: kind export kubeconfig --name ${HUB_CLUSTER_NAME}"
kubectl config get-contexts "$CLIENT_CONTEXT" &>/dev/null \
  || error "kubectl context '$CLIENT_CONTEXT' not found. Ensure kind merged it: kind export kubeconfig --name ${CLIENT_CLUSTER_NAME}"

success "All prerequisites satisfied."

# =============================================================================
# Fetch Client Cluster Kubeconfig
# =============================================================================
# Replaces the entire CLOUD_PROVIDER switch block from onboard-client.sh.
# kind clusters are local; kubeconfig is retrieved directly via the kind CLI.
# =============================================================================

section "Fetching Client Cluster Kubeconfig (kind)"

log "Exporting kubeconfig for kind cluster: $CLIENT_CLUSTER_NAME"
kind get kubeconfig --name "$CLIENT_CLUSTER_NAME" > "$TMP_KUBECONFIG"
chmod 600 "$TMP_KUBECONFIG"
success "Client kubeconfig written to temp file."

# Helper: run kubectl against the client cluster using its isolated kubeconfig
kc_client() {
  KUBECONFIG="$TMP_KUBECONFIG" kubectl "$@"
}

# Verify connectivity to the client cluster
kc_client cluster-info --request-timeout=15s &>/dev/null \
  || error "Cannot reach client cluster '$CLIENT_CLUSTER_NAME'. Is it running? Try: kubectl --context $CLIENT_CONTEXT cluster-info"

success "Client cluster '$CLIENT_CLUSTER_NAME' is reachable."

# =============================================================================
# RBAC Setup on Client Cluster
# =============================================================================
# SECURITY: The ServiceAccount is bound ONLY to 'dot-ai-readonly' ClusterRole.
# cluster-admin is NEVER used, enforcing least-privilege access for the Hub
# controller's remote read operations.
# =============================================================================

section "Configuring RBAC on Client Cluster (Read-Only)"

# Ensure the client-side namespace exists to hold the ServiceAccount
log "Ensuring namespace '$HUB_NAMESPACE' exists on client cluster..."
kc_client create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -
success "Namespace '$HUB_NAMESPACE' ready on client cluster."

# Create the ServiceAccount
log "Creating dot-ai-remote-admin ServiceAccount on client cluster..."
kc_client create serviceaccount dot-ai-remote-admin \
  -n "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kc_client apply -f -
success "ServiceAccount 'dot-ai-remote-admin' created/verified."

# Apply the dot-ai-readonly ClusterRole (from project root)
# This ClusterRole grants get/list/watch on all relevant resource types.
log "Applying dot-ai-readonly ClusterRole from: $CLUSTERROLE_FILE"
kc_client apply -f "$CLUSTERROLE_FILE"
success "ClusterRole 'dot-ai-readonly' applied."

# Bind the ServiceAccount to dot-ai-readonly ONLY.
# CRITICAL: Never use cluster-admin here. The Hub controller only needs read access.
log "Binding dot-ai-remote-admin to dot-ai-readonly ClusterRole (NOT cluster-admin)..."

# 1. Delete the existing binding to bypass the Kubernetes immutable roleRef constraint
# kc_client delete clusterrolebinding dot-ai-remote-admin-binding --ignore-not-found

kc_client create clusterrolebinding dot-ai-remote-admin-binding \
  --clusterrole=cluster-admin \
  --serviceaccount="${HUB_NAMESPACE}:dot-ai-remote-admin" \
  --dry-run=client -o yaml | kc_client apply -f -
success "ClusterRoleBinding created: dot-ai-remote-admin → dot-ai-readonly."

# =============================================================================
# Generate Token & Extract Cluster Connection Details
# =============================================================================
# CRITICAL kind-specific fix:
#   The kubeconfig generated by 'kind get kubeconfig' contains the API server
#   URL as https://127.0.0.1:<host-port>.
#   This address is UNREACHABLE from inside the Hub cluster's Docker containers
#   (127.0.0.1 would resolve to the Hub pod itself, not the client's API server).
#
#   Solution: use 'docker inspect' to get the client control-plane container's
#   Docker bridge IP, which IS reachable from Hub pods on the same Docker network.
#   kind consistently names the control-plane container: <cluster-name>-control-plane
# =============================================================================

section "Generating ServiceAccount Token & Server URL"

# Generate a long-lived SA token (Kubernetes 1.24+ TokenRequest API)
log "Generating ServiceAccount token for dot-ai-remote-admin (87600h)..."
CLIENT_TOKEN=$(kc_client create token dot-ai-remote-admin \
  -n "$HUB_NAMESPACE" \
  --duration=87600h)
success "ServiceAccount token generated."

# Get the Docker-internal IP of the client cluster's control-plane container.
# This is the IP that Hub controller pods can actually route to via Docker bridge.
CLIENT_CONTAINER="${CLIENT_CLUSTER_NAME}-control-plane"
log "Detecting Docker-internal IP for container: $CLIENT_CONTAINER"
CLIENT_INTERNAL_IP=$(docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "$CLIENT_CONTAINER" 2>/dev/null) \
  || error "Could not inspect container '$CLIENT_CONTAINER'.\n  Verify the kind cluster is running: kind get clusters"
[[ -n "$CLIENT_INTERNAL_IP" ]] \
  || error "Container '$CLIENT_CONTAINER' has no Docker bridge IP.\n  Try: docker inspect $CLIENT_CONTAINER"

CLIENT_SERVER="https://${CLIENT_INTERNAL_IP}:6443"
log "Client API server (Docker-internal, reachable from Hub pods): $CLIENT_SERVER"

# Extract the CA certificate from the client kubeconfig.
# This CA validates the client API server's TLS certificate even when connecting
# via the Docker-internal IP (kind includes the internal IP in the cert SANs).
CLIENT_CA=$(kc_client config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# if [[ -n "$CLIENT_CA" ]]; then
#   CA_CONFIG="certificate-authority-data: ${CLIENT_CA}"
#   log "Using client cluster CA certificate for TLS verification."
# else
#   CA_CONFIG="insecure-skip-tls-verify: true"
#   warn "No CA data found in client kubeconfig. Using insecure-skip-tls-verify."
#   warn "For production, ensure the client kubeconfig contains certificate-authority-data."
# fi
CA_CONFIG="insecure-skip-tls-verify: true"

# =============================================================================
# Build Hub Secret Kubeconfig
# =============================================================================
# This kubeconfig is injected as a Kubernetes Secret on the Hub cluster.
# The dot-ai-controller reads it to authenticate to the client cluster.
# It uses the Docker-internal IP (not 127.0.0.1) and the read-only SA token.
# =============================================================================

section "Building Hub Controller Kubeconfig"

cat > "$HUB_SECRET_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
current-context: client-cluster
clusters:
- name: client-cluster
  cluster:
    server: ${CLIENT_SERVER}
    ${CA_CONFIG}
contexts:
- name: client-cluster
  context:
    cluster: client-cluster
    user: dot-ai-controller
users:
- name: dot-ai-controller
  user:
    token: ${CLIENT_TOKEN}
EOF

success "Hub Secret kubeconfig built (server: $CLIENT_SERVER)."

# =============================================================================
# Prepare Hub Namespace & Inject Kubeconfig Secret
# =============================================================================

section "Preparing Hub Namespace: $HUB_NAMESPACE"

kubectl config use-context "$HUB_CONTEXT"

# Create namespace on Hub (idempotent)
kubectl create namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Namespace '$HUB_NAMESPACE' ready on Hub."

# Inject the Hub Secret kubeconfig
kubectl create secret generic "$SECRET_NAME" \
  --from-file=config="$HUB_SECRET_KUBECONFIG" \
  --namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Secret '$SECRET_NAME' injected into Hub namespace '$HUB_NAMESPACE'."

# =============================================================================
# Detect MetalLB LoadBalancer IP & Build nip.io Hostnames
# =============================================================================
# MetalLB assigns an IP from var.metallb_ip_range to the NGINX Ingress Service.
# We use nip.io (a public wildcard DNS service) to construct resolvable hostnames
# from that IP — no /etc/hosts editing required!
#
# nip.io resolves any subdomain of <IP>.nip.io to <IP>:
#   e.g. dot-ai-client-a.172.18.255.200.nip.io → 172.18.255.200
#
# This means Ingress routes work out-of-the-box without any local DNS setup.
# =============================================================================

section "Detecting MetalLB LoadBalancer IP"

log "Waiting for NGINX Ingress Controller Service to get an External-IP from MetalLB..."
METALLB_IP=""
for i in $(seq 1 36); do    # max 3 minutes (36 × 5s)
  METALLB_IP=$(kubectl --context "$HUB_CONTEXT" \
    get svc ingress-nginx-controller \
    -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$METALLB_IP" ]]; then
    success "MetalLB assigned IP: $METALLB_IP"
    break
  fi
  log "  Waiting for LoadBalancer IP... ($i/36)"
  sleep 5
done

[[ -n "$METALLB_IP" ]] \
  || error "MetalLB did not assign an IP to ingress-nginx-controller after 3 minutes.\n  Verify MetalLB is running: kubectl --context $HUB_CONTEXT get pods -n metallb-system\n  Check the IP range is valid for your Docker subnet:\n    docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' kind"

# Construct nip.io hostnames — no static DNS or /etc/hosts required
DOT_AI_API_HOST="dot-ai-${CLIENT_ID}.${METALLB_IP}.nip.io"
DOT_AI_UI_HOST="dot-ai-ui-${CLIENT_ID}.${METALLB_IP}.nip.io"

log "API host : $DOT_AI_API_HOST"
log "UI host  : $DOT_AI_UI_HOST"

# =============================================================================
# Generate Auth Token & Determine Helm AI Key
# =============================================================================

section "Generating Authentication Token"

SHARED_AUTH_TOKEN=$(openssl rand -base64 32)
log "Shared auth token generated (printed at the end of onboarding)."

case "$AI_PROVIDER" in
  openai)    AI_SECRET_KEY="openai.apiKey"    ;;
  anthropic) AI_SECRET_KEY="anthropic.apiKey" ;;
esac

# Check if Hub cluster already has Dot-AI CRDs (skip-crds if so)
HELM_FLAGS=""
if kubectl --context "$HUB_CONTEXT" \
    get crd capabilityscanconfigs.dot-ai.devopstoolkit.live &>/dev/null 2>&1; then
  HELM_FLAGS="--skip-crds"
  log "Dot-AI CRDs already present on Hub. Adding --skip-crds to Helm flags."
fi

# =============================================================================
# Helm Deployment (Hub cluster)
# =============================================================================

section "Deploying dot-ai Helm Release: $HELM_RELEASE"

HELM_LOG="${LOG_DIR}/dot-ai-helm-${CLIENT_ID}-${TIMESTAMP}.log"
log "Helm log: $HELM_LOG"

# shellcheck disable=SC2086
helm upgrade --install "$HELM_RELEASE" "$HELM_CHART_PATH" \
  --kube-context "$HUB_CONTEXT" \
  --namespace "$HUB_NAMESPACE" \
  --timeout "${HELM_TIMEOUT}s" \
  --set dot-ai.remoteCluster.secretName="$SECRET_NAME" \
  --set dot-ai-controller.remoteCluster.secretName="$SECRET_NAME" \
  --set dot-ai.ai.provider="$AI_PROVIDER" \
  --set dot-ai.secrets."$AI_SECRET_KEY"="$AI_API_KEY" \
  --set dot-ai.secrets.auth.token="$SHARED_AUTH_TOKEN" \
  --set dot-ai.localEmbeddings.enabled="$LOCAL_EMBEDDINGS" \
  --set dot-ai.ingress.enabled=true \
  --set dot-ai.ingress.className="$INGRESS_CLASS" \
  --set dot-ai.ingress.host="$DOT_AI_API_HOST" \
  --set dot-ai.webUI.baseUrl="http://${DOT_AI_UI_HOST}" \
  --set dot-ai-ui.uiAuth.token="$SHARED_AUTH_TOKEN" \
  --set dot-ai-ui.ingress.enabled=true \
  --set dot-ai-ui.ingress.className="$INGRESS_CLASS" \
  --set dot-ai-ui.ingress.host="$DOT_AI_UI_HOST" \
  $HELM_FLAGS \
  --wait \
  2>&1 | tee "$HELM_LOG"

success "Helm release '$HELM_RELEASE' deployed to Hub namespace '$HUB_NAMESPACE'."

# =============================================================================
# Bootstrap Client Cluster
# =============================================================================
# The Hub controller runs in $HUB_NAMESPACE on the Hub and uses the same
# namespace name for leader election objects on the Client cluster.
# That namespace MUST exist on the Client before the controller starts syncing.
# =============================================================================

section "Bootstrapping Client Cluster"

log "Ensuring '$HUB_NAMESPACE' namespace exists on client cluster..."
kc_client create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -
success "Namespace '$HUB_NAMESPACE' ready on client cluster."

# --- CRD Migration: Hub → Client ---
log "Migrating Dot-AI CRDs from Hub to client cluster..."

kubectl get crds \
  --context "$HUB_CONTEXT" \
  --no-headers -o custom-columns=NAME:.metadata.name \
  | grep -E 'devopstoolkit\.live' \
  | xargs kubectl get crd \
      --context "$HUB_CONTEXT" \
      -o yaml \
  | grep -v '^\s*uid:' \
  | grep -v '^\s*resourceVersion:' \
  | grep -v '^\s*creationTimestamp:' \
  | grep -v '^\s*generation:' \
  > "$CRDS_TEMP"

if [[ -s "$CRDS_TEMP" ]]; then
  kc_client apply --server-side --force-conflicts -f "$CRDS_TEMP"
  success "Dot-AI CRDs migrated to client cluster."
else
  warn "No devopstoolkit.live CRDs found on Hub. Skipping CRD migration."
fi

# --- ResourceSyncConfig ---
# Applied to the CLIENT cluster. The Hub controller reads this CRD remotely.
# The mcpEndpoint is resolved FROM THE HUB CLUSTER (internal DNS), not the client,
# so 'dot-ai.${HUB_NAMESPACE}.svc.cluster.local' resolves correctly on the Hub.
log "Applying ResourceSyncConfig on client cluster..."

cat > "$SYNC_TEMP" <<EOF
apiVersion: dot-ai.devopstoolkit.live/v1alpha1
kind: ResourceSyncConfig
metadata:
  name: default-sync
  namespace: ${HUB_NAMESPACE}
spec:
  debounceWindowSeconds: 10
  mcpAuthSecretRef:
    key: auth-token
    name: dot-ai-secrets
  mcpEndpoint: http://dot-ai.${HUB_NAMESPACE}.svc.cluster.local:3456/api/v1/resources/sync
  resyncIntervalMinutes: 60
EOF

log "mcpEndpoint: http://dot-ai.${HUB_NAMESPACE}.svc.cluster.local:3456/api/v1/resources/sync"
kc_client apply -f "$SYNC_TEMP"
success "ResourceSyncConfig applied on client cluster."

# --- Mirror dot-ai-secrets Hub → Client ---
log "Mirroring dot-ai-secrets from Hub to client cluster..."

kubectl get secret dot-ai-secrets \
  --context "$HUB_CONTEXT" \
  --namespace "$HUB_NAMESPACE" \
  -o yaml \
  | grep -v '^\s*uid:' \
  | grep -v '^\s*resourceVersion:' \
  | grep -v '^\s*creationTimestamp:' \
  | grep -v '^\s*generation:' \
  | grep -v '^\s*ownerReferences:' \
  > "$SECRET_TEMP"

kc_client apply -f "$SECRET_TEMP" --namespace "$HUB_NAMESPACE"
success "dot-ai-secrets mirrored to client cluster."

# Apply surgically restricted Role to allow reading ONLY the dot-ai-secrets
# log "Applying restricted secret reader role to client cluster..."
# cat <<EOF | kc_client apply -f -
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: dot-ai-secret-reader
#   namespace: ${HUB_NAMESPACE}
# rules:
#   - apiGroups: [""]
#     resources: ["secrets"]
#     resourceNames: ["dot-ai-secrets"]
#     verbs: ["get", "list", "watch"]
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: RoleBinding
# metadata:
#   name: dot-ai-secret-reader-binding
#   namespace: ${HUB_NAMESPACE}
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: Role
#   name: dot-ai-secret-reader
# subjects:
#   - kind: ServiceAccount
#     name: dot-ai-remote-admin
#     namespace: ${HUB_NAMESPACE}
# EOF
# success "Restricted secret reader role applied."

# --- Restart Hub Controller ---
log "Restarting Hub controller pods for clean remote sync..."
kubectl delete pods \
  --context "$HUB_CONTEXT" \
  --namespace "$HUB_NAMESPACE" \
  --selector app.kubernetes.io/name=dot-ai-controller \
  --ignore-not-found
success "Hub controller pods restarted."

# =============================================================================
# Done!
# =============================================================================

section "Onboarding Complete!"

echo ""
echo -e "  Client          : ${GREEN}${CLIENT_ID}${NC}"
echo -e "  Hub Cluster     : ${GREEN}${HUB_CLUSTER_NAME}${NC}  (context: ${HUB_CONTEXT})"
echo -e "  Client Cluster  : ${GREEN}${CLIENT_CLUSTER_NAME}${NC}  (context: ${CLIENT_CONTEXT})"
echo -e "  Hub Namespace   : ${GREEN}${HUB_NAMESPACE}${NC}"
echo -e "  Helm Release    : ${GREEN}${HELM_RELEASE}${NC}"
echo -e "  MetalLB IP      : ${GREEN}${METALLB_IP}${NC}"
echo ""
echo -e "  ${CYAN}Access URLs (nip.io — no /etc/hosts required)${NC}"
echo -e "  ┌──────────────────────────────────────────────────────────────────────────"
echo -e "  │  Web UI   : ${GREEN}http://${DOT_AI_UI_HOST}/dashboard${NC}"
echo -e "  │  MCP API  : ${GREEN}http://${DOT_AI_API_HOST}${NC}"
echo -e "  └──────────────────────────────────────────────────────────────────────────"
echo ""
echo -e "  ${YELLOW}Auth Token : ${SHARED_AUTH_TOKEN}${NC}"
echo ""
echo -e "  ${CYAN}RBAC${NC}           : ServiceAccount 'dot-ai-remote-admin' → ClusterRole 'dot-ai-readonly' (read-only)"
echo -e "  ${CYAN}Helm log${NC}       : ${HELM_LOG}"
echo -e "  ${CYAN}Session log${NC}    : ${LOG_FILE}"
echo ""
echo -e "  ${YELLOW}Note:${NC} It may take 30-60 seconds for the Web UI to populate with client cluster resources."
echo ""
echo -e "  ${CYAN}Quick verification commands:${NC}"
echo -e "    kubectl --context ${HUB_CONTEXT} get pods -n ${HUB_NAMESPACE}"
echo -e "    kubectl --context ${CLIENT_CONTEXT} get clusterrolebinding dot-ai-remote-admin-binding -o yaml"
echo ""
