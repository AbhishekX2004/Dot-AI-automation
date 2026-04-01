#!/usr/bin/env bash

# =============================================================================
# onboard-client.sh — Dot-AI Client Onboarding Script
# =============================================================================
# Usage:
#   ./onboard-client.sh <vars-file>
#
# Example:
#   cp client.vars acme-corp.vars
#   # edit acme-corp.vars
#   ./onboard-client.sh acme-corp.vars
#
# What this script does:
#   1.  Loads and validates the client vars file
#   2.  Fetches the client kubeconfig (EKS / GKE / ACP / file)
#   3.  Creates a dedicated namespace on the Hub for this client
#   4.  Injects the client kubeconfig as a Hub Secret
#   5.  Deploys a scoped dot-ai Helm release into the client namespace
#   6.  Bootstraps the client cluster (namespace, CRDs, sync config, secrets)
#   7.  Restarts the Hub controller to trigger a clean sync
#
# Prerequisites:
#   kubectl, helm, openssl
#   aws CLI    (for CLOUD_PROVIDER=eks)
#   gcloud CLI (for CLOUD_PROVIDER=gke)
#   curl       (for CLOUD_PROVIDER=acp)
# =============================================================================
set -euo pipefail

# Helpers

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo ""; echo -e "${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

require_cmd() { command -v "$1" &>/dev/null || error "Required command not found: $1. Please install it."; }

# Load Vars File
VARS_FILE="${1:-}"
[[ -z "$VARS_FILE" ]] && error "Usage: $0 <vars-file>\n  Example: $0 acme-corp.vars"
[[ -f "$VARS_FILE" ]] || error "vars file not found: $VARS_FILE"

# shellcheck source=/dev/null
source "$VARS_FILE"
log "Loaded config from: $VARS_FILE"

# Validate Required Fields
section "Validating Configuration"

_require_var() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || error "Required variable \$$name is not set in $VARS_FILE"
}

_require_var CLIENT_ID
_require_var HUB_CONTEXT
_require_var CLOUD_PROVIDER
_require_var BASE_DOMAIN
_require_var INGRESS_CLASS
_require_var AI_PROVIDER
_require_var AI_API_KEY

# Validate CLIENT_ID format (lowercase letters, numbers, hyphens only)
if ! echo "$CLIENT_ID" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
  error "CLIENT_ID '$CLIENT_ID' is invalid. Use only lowercase letters, numbers, and hyphens (e.g. acme-corp)."
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="onboard-logs-${CLIENT_ID}-${TIMESTAMP}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/onboard.log"

exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging output to $LOG_FILE"

save_and_clean_tmp() {
  for f in "$@"; do
    if [[ -f "$f" ]]; then
      cp "$f" "$LOG_DIR/" 2>/dev/null || true
      rm -f "$f"
    fi
  done
}

# Validate CLOUD_PROVIDER
case "$CLOUD_PROVIDER" in
  eks|gke|aks|acp|file) ;;
  *) error "CLOUD_PROVIDER must be one of: eks, gke, aks, acp, file. Got: $CLOUD_PROVIDER" ;;
esac

# Validate AI_PROVIDER
case "$AI_PROVIDER" in
  openai|anthropic) ;;
  *) error "AI_PROVIDER must be 'openai' or 'anthropic'. Got: $AI_PROVIDER" ;;
esac

# Set defaults for optional vars
HELM_TIMEOUT="${HELM_TIMEOUT:-600}"
HELM_CHART_PATH="${HELM_CHART_PATH:-./dot-ai-stack}"
LOCAL_EMBEDDINGS="${LOCAL_EMBEDDINGS:-true}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
HELM_FLAGS=""
if kubectl --context "$HUB_CONTEXT" get crd capabilityscanconfigs.dot-ai.devopstoolkit.live >/dev/null 2>&1; then
  HELM_FLAGS="--skip-crds"
fi

# Derived names
HUB_NAMESPACE="$CLIENT_ID"
HELM_RELEASE="dot-ai-${CLIENT_ID}"
AGENT_SECRET_NAME="client-${CLIENT_ID}-agent-kubeconfig"
CONTROLLER_SECRET_NAME="client-${CLIENT_ID}-controller-kubeconfig"
TMP_KUBECONFIG=$(mktemp /tmp/dot-ai-client-kubeconfig-XXXXXX)
CONTROLLER_KUBECONFIG=$(mktemp /tmp/dot-ai-controller-kubeconfig-XXXXXX)
AGENT_KUBECONFIG=$(mktemp /tmp/dot-ai-agent-kubeconfig-XXXXXX)
# Ensure temp file is cleaned up on exit
trap 'save_and_clean_tmp "$TMP_KUBECONFIG"' EXIT

# Locate the ClusterRole file
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTERROLE_FILE="${SCRIPT_DIR}/hub-readonly-role.yaml"
AGENTROLE_FILE="${SCRIPT_DIR}/dot-ai-agent-role.yaml"
[[ -f "$CLUSTERROLE_FILE" ]] || error "ClusterRole file not found: $CLUSTERROLE_FILE"
[[ -f "$AGENTROLE_FILE" ]] || error "Agent ClusterRole file not found: $AGENTROLE_FILE"

success "Configuration valid. Client ID: $CLIENT_ID | Provider: $CLOUD_PROVIDER"

# Check Prerequisites
require_cmd kubectl
require_cmd helm
require_cmd openssl

case "$CLOUD_PROVIDER" in
  eks)  require_cmd aws     ;;
  gke)  require_cmd gcloud  ;;
  aks)  require_cmd az      ;;
  acp)  require_cmd curl    ;;
esac

# Verify Helm chart exists
[[ -d "$HELM_CHART_PATH" ]] || error "Helm chart not found at: $HELM_CHART_PATH"

# Verify Hub context exists
kubectl config get-contexts "$HUB_CONTEXT" &>/dev/null \
  || error "kubectl context '$HUB_CONTEXT' not found. Run: kubectl config get-contexts"

# Fetch Client Kubeconfig
section "Fetching Client Cluster Kubeconfig (${CLOUD_PROVIDER})"

case "$CLOUD_PROVIDER" in

  # EKS
  eks)
    _require_var AWS_REGION
    _require_var EKS_CLUSTER_NAME

    log "Fetching EKS kubeconfig for cluster: $EKS_CLUSTER_NAME in $AWS_REGION"

    AWS_PROFILE_ARG=""
    [[ -n "${AWS_PROFILE:-}" ]] && AWS_PROFILE_ARG="--profile $AWS_PROFILE"

    # shellcheck disable=SC2086
    aws eks update-kubeconfig \
      --name "$EKS_CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --kubeconfig "$TMP_KUBECONFIG" \
      $AWS_PROFILE_ARG

    success "EKS kubeconfig written to temp file."
    ;;

  # GKE
  gke)
    _require_var GKE_PROJECT
    _require_var GKE_CLUSTER_NAME
    _require_var GKE_ZONE

    log "Fetching GKE kubeconfig for cluster: $GKE_CLUSTER_NAME in $GKE_ZONE"

    # gcloud writes to KUBECONFIG env-var path
    KUBECONFIG="$TMP_KUBECONFIG" gcloud container clusters get-credentials \
      "$GKE_CLUSTER_NAME" \
      --project "$GKE_PROJECT" \
      --zone "$GKE_ZONE"

    success "GKE kubeconfig written to temp file."
    ;;

  # AKS
  aks)
    _require_var AKS_RESOURCE_GROUP
    _require_var AKS_CLUSTER_NAME

    log "Fetching AKS kubeconfig for cluster: $AKS_CLUSTER_NAME in $AKS_RESOURCE_GROUP"

    if [[ -n "${AKS_SUBSCRIPTION_ID:-}" ]]; then
      az account set --subscription "$AKS_SUBSCRIPTION_ID"
    fi

    # az aks get-credentials writes to ~/.kube/config by default but we can use --file
    az aks get-credentials \
      --resource-group "$AKS_RESOURCE_GROUP" \
      --name "$AKS_CLUSTER_NAME" \
      --file "$TMP_KUBECONFIG" \
      --overwrite-existing

    success "AKS kubeconfig written to temp file."
    ;;

  # ACP / Generic bearer-token cluster
  acp)
    _require_var ACP_SERVER_URL
    _require_var ACP_TOKEN

    log "Building kubeconfig for ACP cluster: $ACP_SERVER_URL"

    INSECURE_FLAG=""
    [[ "${ACP_INSECURE:-false}" == "true" ]] && INSECURE_FLAG="insecure-skip-tls-verify: true"

    # Build a minimal kubeconfig using the bearer token.
    cat > "$TMP_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
current-context: acp-${CLIENT_ID}
clusters:
- name: acp-${CLIENT_ID}
  cluster:
    server: ${ACP_SERVER_URL}
    ${INSECURE_FLAG}
contexts:
- name: acp-${CLIENT_ID}
  context:
    cluster: acp-${CLIENT_ID}
    user: acp-${CLIENT_ID}-user
users:
- name: acp-${CLIENT_ID}-user
  user:
    token: ${ACP_TOKEN}
EOF

    # Validate connectivity
    if ! KUBECONFIG="$TMP_KUBECONFIG" kubectl version --short &>/dev/null; then
      warn "Could not reach ACP cluster at $ACP_SERVER_URL. Continuing anyway — verify the URL and token."
    else
      success "ACP cluster reachable."
    fi
    ;;

  # File
  file)
    _require_var KUBECONFIG_FILE
    [[ -f "$KUBECONFIG_FILE" ]] || error "KUBECONFIG_FILE not found: $KUBECONFIG_FILE"

    cp "$KUBECONFIG_FILE" "$TMP_KUBECONFIG"

    # If a specific context was specified, switch to it
    if [[ -n "${KUBECONFIG_FILE_CONTEXT:-}" ]]; then
      KUBECONFIG="$TMP_KUBECONFIG" kubectl config use-context "$KUBECONFIG_FILE_CONTEXT" \
        || error "Context '$KUBECONFIG_FILE_CONTEXT' not found in $KUBECONFIG_FILE"
      log "Switched to context: $KUBECONFIG_FILE_CONTEXT"
    fi

    success "Kubeconfig loaded from file: $KUBECONFIG_FILE"
    ;;
esac

# Store the context name we'll use to talk to the client cluster
CLIENT_CONTEXT=$(KUBECONFIG="$TMP_KUBECONFIG" kubectl config current-context)
log "Client cluster context: $CLIENT_CONTEXT"

# Prepare Hub Namespace & Inject Kubeconfig Secret
section "Preparing Hub Namespace: $HUB_NAMESPACE"

# create a ServiceAccount and use its token so Hub controller can authenticate.
kc_client() {
  KUBECONFIG="$TMP_KUBECONFIG" kubectl "$@"
}

log "Creating dual ServiceAccounts on client cluster..."
# Ensure the client-side namespace exists first to hold the SAs
kc_client create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -

kc_client create serviceaccount dot-ai-controller-admin -n "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -
kc_client create serviceaccount dot-ai-agent -n "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -

log "Applying ClusterRoles..."
kc_client apply -f "$CLUSTERROLE_FILE"
kc_client apply -f "$AGENTROLE_FILE"

log "Binding identities to specific roles..."
kc_client create clusterrolebinding dot-ai-controller-admin-binding \
  --clusterrole=hub-readonly \
  --serviceaccount="${HUB_NAMESPACE}:dot-ai-controller-admin" \
  --dry-run=client -o yaml | kc_client apply -f -

kc_client create clusterrolebinding dot-ai-agent-binding \
  --clusterrole=dot-ai-agent-role \
  --serviceaccount="${HUB_NAMESPACE}:dot-ai-agent" \
  --dry-run=client -o yaml | kc_client apply -f -
success "ClusterRoleBindings established successfully."

# Generate explicit tokens (requires Kubernetes 1.24+ TokenRequest API)
log "Generating explicit tokens for Controller and Agent..."
CONTROLLER_TOKEN=$(kc_client create token dot-ai-controller-admin -n "$HUB_NAMESPACE" --duration=87600h)
AGENT_TOKEN=$(kc_client create token dot-ai-agent -n "$HUB_NAMESPACE" --duration=87600h)

# Extract Server URL and CA Data from the original kubeconfig
CLIENT_SERVER=$(kc_client config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLIENT_CA=$(kc_client config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Build clean kubeconfigs for the Hub pieces
trap 'save_and_clean_tmp "$TMP_KUBECONFIG" "$CONTROLLER_KUBECONFIG" "$AGENT_KUBECONFIG"' EXIT

if [[ -n "$CLIENT_CA" ]]; then
  CA_CONFIG="certificate-authority-data: ${CLIENT_CA}"
else
  CA_CONFIG="insecure-skip-tls-verify: true"
fi

cat > "$CONTROLLER_KUBECONFIG" <<EOF
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
    token: ${CONTROLLER_TOKEN}
EOF

cat > "$AGENT_KUBECONFIG" <<EOF
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
    user: dot-ai-agent
users:
- name: dot-ai-agent
  user:
    token: ${AGENT_TOKEN}
EOF

# Switch to Hub
kubectl config use-context "$HUB_CONTEXT"

# Create namespace (idempotent)
kubectl create namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Namespace '$HUB_NAMESPACE' ready on Hub."

# Inject kubeconfigs as Secrets
kubectl create secret generic "$CONTROLLER_SECRET_NAME" \
  --from-file=config="$CONTROLLER_KUBECONFIG" \
  --namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
  
kubectl create secret generic "$AGENT_SECRET_NAME" \
  --from-file=config="$AGENT_KUBECONFIG" \
  --namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Secret credentials injected into namespace '$HUB_NAMESPACE'."

# Generate Auth Token
section "Generating Authentication Token"

SHARED_AUTH_TOKEN=$(openssl rand -base64 32)
log "Shared auth token generated (will be printed at the end)."

# Determine Helm secret key for the AI provider
case "$AI_PROVIDER" in
  openai)    AI_SECRET_KEY="openai.apiKey"    ;;
  anthropic) AI_SECRET_KEY="anthropic.apiKey" ;;
esac

# Helm Deployment
section "Deploying dot-ai Helm Release: $HELM_RELEASE"

HELM_LOG="${LOG_DIR}/dot-ai-helm-${CLIENT_ID}-${TIMESTAMP}.log"

DOT_AI_API_HOST="dot-ai-${CLIENT_ID}.${BASE_DOMAIN}"
DOT_AI_UI_HOST="dot-ai-ui-${CLIENT_ID}.${BASE_DOMAIN}"

log "Helm log: $HELM_LOG"
log "API host : $DOT_AI_API_HOST"
log "UI host  : $DOT_AI_UI_HOST"

helm upgrade --install "$HELM_RELEASE" "$HELM_CHART_PATH" \
  --namespace "$HUB_NAMESPACE" \
  --timeout "${HELM_TIMEOUT}s" \
  --set dot-ai.remoteCluster.secretName="$AGENT_SECRET_NAME" \
  --set dot-ai-controller.remoteCluster.secretName="$CONTROLLER_SECRET_NAME" \
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

success "Helm release '$HELM_RELEASE' deployed."

# Bootstrap Client Cluster
section "Bootstrapping Client Cluster"

# The controller runs on the Hub in $HUB_NAMESPACE, and uses that same namespace name
# for leader election on the Client cluster. So it MUST exist on the Client!
log "Ensuring '$HUB_NAMESPACE' namespace exists on client cluster..."
kc_client create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -
success "Namespace '$HUB_NAMESPACE' ready on client cluster."

# Migrate CRDs from Hub to Client
log "Migrating Dot-AI CRDs from Hub to client cluster..."
CRDS_TEMP=$(mktemp /tmp/dot-ai-crds-XXXXXX.yaml)
trap 'save_and_clean_tmp "$TMP_KUBECONFIG" "$CONTROLLER_KUBECONFIG" "$AGENT_KUBECONFIG" "$CRDS_TEMP"' EXIT

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
  success "CRDs migrated to client cluster."
else
  warn "No devopstoolkit.live CRDs found on Hub. Skipping CRD migration."
fi

# Apply ResourceSyncConfig on client cluster
log "Applying ResourceSyncConfig on client cluster..."
SYNC_TEMP=$(mktemp /tmp/dot-ai-sync-XXXXXX.yaml)
trap 'save_and_clean_tmp "$TMP_KUBECONFIG" "$CONTROLLER_KUBECONFIG" "$AGENT_KUBECONFIG" "$CRDS_TEMP" "$SYNC_TEMP"' EXIT

# The Hub controller reads this CRD remotely, and performs the sync itself.
# Using the internal Hub service URL ensures it works regardless of NAT hairpinning
# or external DNS propagation.
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

# Mirror dot-ai-secrets from Hub to Client
log "Mirroring dot-ai-secrets from Hub to client cluster..."
SECRET_TEMP=$(mktemp /tmp/dot-ai-secret-XXXXXX.yaml)
trap 'save_and_clean_tmp "$TMP_KUBECONFIG" "$CONTROLLER_KUBECONFIG" "$AGENT_KUBECONFIG" "$CRDS_TEMP" "$SYNC_TEMP" "$SECRET_TEMP"' EXIT

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

# Restart Hub controller to trigger a clean remote sync
log "Restarting Hub controller pod for clean sync..."
kubectl delete pods \
  --context "$HUB_CONTEXT" \
  --namespace "$HUB_NAMESPACE" \
  --selector app.kubernetes.io/name=dot-ai-controller \
  --ignore-not-found
success "Hub controller pods restarted."

# Done!
section "Onboarding Complete!"

echo ""
echo -e "  Client     : ${GREEN}${CLIENT_ID}${NC}"
echo -e "  Provider   : ${GREEN}${CLOUD_PROVIDER}${NC}"
echo -e "  Namespace  : ${GREEN}${HUB_NAMESPACE}${NC}"
echo -e "  Helm Release: ${GREEN}${HELM_RELEASE}${NC}"
echo ""
echo -e "  ${CYAN}Access URLs${NC}"
echo -e "  ┌─────────────────────────────────────────────────────────────────"
echo -e "  │  Web UI   : ${GREEN}http://${DOT_AI_UI_HOST}/dashboard${NC}"
echo -e "  │  MCP API  : ${GREEN}http://${DOT_AI_API_HOST}${NC}"
echo -e "  └─────────────────────────────────────────────────────────────────"
echo ""
echo -e "  ${YELLOW}Auth Token : ${SHARED_AUTH_TOKEN}${NC}"
echo ""
echo -e "  ${CYAN}Helm log saved to: $HELM_LOG${NC}"
echo ""
echo -e "  Note: It may take 30-60 seconds for the UI to populate with client cluster resources."
echo ""
