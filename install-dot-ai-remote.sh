#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "DevOps AI Toolkit Stack Installer (Hub-and-Spoke Edition)"

# Safety Check: Ensure the Spoke cluster exists before starting the Hub installation
if ! kind get clusters 2>/dev/null | grep -q '^client-1$'; then
    echo "Error: 'client-1' cluster not found!"
    echo "Please run './setup-client.sh' first to spin up the remote cluster."
    exit 1
fi

# Determine Environment (Local vs Deployed)
read -p "Do you want to deploy locally using Kind or use an existing cluster? (local/existing): " ENV_TYPE

if [[ "$ENV_TYPE" == "local" ]]; then
    read -p "Do you want to create a NEW Kind cluster or use an EXISTING local cluster? (new/existing): " LOCAL_CHOICE
    
    if [[ "$LOCAL_CHOICE" == "new" ]]; then
        echo "Starting local deployment using a new Kind cluster..."
        
        if kind get clusters 2>/dev/null | grep -q '^dot-ai-stack$'; then
            echo "Cluster 'dot-ai-stack' already exists. Deleting it..."
            kind delete cluster --name dot-ai-stack
        fi
        
        # Write to a temporary file
        cat << 'EOF' > kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.29.2
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

        # Create the cluster using the file, then clean up
        kind create cluster --name dot-ai-stack --config kind-config.yaml
        rm kind-config.yaml

        echo "Installing Nginx Ingress Controller..."
        kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
        
        echo "Waiting for Ingress Controller to be ready..."
        sleep 15
        kubectl wait --namespace ingress-nginx \
          --for=condition=ready pod \
          --selector=app.kubernetes.io/component=controller \
          --timeout=120s
    elif [[ "$LOCAL_CHOICE" == "existing" ]]; then
        echo "Using existing local cluster..."
        kubectl config use-context kind-dot-ai-stack
    else
        echo "Invalid input. Please enter 'new' or 'existing'."
        exit 1
    fi

    BASE_DOMAIN="127.0.0.1.nip.io"

elif [[ "$ENV_TYPE" == "existing" ]]; then
    echo "Using existing Kubernetes cluster..."
    kubectl config current-context
    read -p "Is this the correct cluster context? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Please switch to the correct kubectl context and run this script again."
        exit 1
    fi
    
    read -p "Enter your base domain for ingress (e.g., example.com): " BASE_DOMAIN
else
    echo "Invalid input. Please enter 'local' or 'existing'."
    exit 1
fi

# AI Provider Configuration
echo "----------------------------------------------"
echo "Select AI Provider:"
echo "1) OpenAI"
echo "2) Anthropic"
read -p "Choice (1/2): " AI_CHOICE

if [[ "$AI_CHOICE" == "1" ]]; then
    read -p "Enter your OpenAI API Key: " API_KEY
    AI_PROVIDER="openai"
    SECRET_KEY="openai.apiKey"
elif [[ "$AI_CHOICE" == "2" ]]; then
    read -p "Enter your Anthropic API Key: " API_KEY
    AI_PROVIDER="anthropic"
    SECRET_KEY="anthropic.apiKey"
else
    echo "Invalid choice."
    exit 1
fi

# Generate Authentication Tokens (UNIFIED to prevent 401 errors)
echo "Generating secure authentication token..."
# SHARED_AUTH_TOKEN="testing"
SHARED_AUTH_TOKEN=$(openssl rand -base64 32)

# --- AUTOMATED CROSS-CLUSTER KUBECONFIG INJECTION ---
echo "----------------------------------------------"
echo "Extracting Client 1 Kubeconfig & Injecting into Hub..."

CLIENT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-1-control-plane)

docker exec client-1-control-plane cat /etc/kubernetes/admin.conf > fresh.kubeconfig
CLUSTER_NAME=$(kubectl config view --kubeconfig=fresh.kubeconfig -o jsonpath='{.clusters[0].name}')
kubectl config set-cluster $CLUSTER_NAME --server=https://$CLIENT_IP:6443 --kubeconfig=fresh.kubeconfig
kubectl config set-cluster $CLUSTER_NAME --insecure-skip-tls-verify=true --kubeconfig=fresh.kubeconfig
kubectl config unset clusters.$CLUSTER_NAME.certificate-authority-data --kubeconfig=fresh.kubeconfig

kubectl config use-context kind-dot-ai-stack
kubectl create namespace dot-ai --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic client-cluster-kubeconfig \
  --from-file=config=fresh.kubeconfig \
  --namespace dot-ai \
  --dry-run=client -o yaml | kubectl apply -f -
  
rm fresh.kubeconfig
echo "Remote Kubeconfig successfully injected!"

# Helm Deployment
echo "----------------------------------------------"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HELM_LOG="dot-ai-helm-${TIMESTAMP}.log"
echo "Installing custom dot-ai-stack via Helm... (Logging output to $HELM_LOG)"

helm upgrade --install dot-ai-stack ./dot-ai-stack \
  --namespace dot-ai \
  --set dot-ai.remoteCluster.secretName="client-cluster-kubeconfig" \
  --set dot-ai-controller.remoteCluster.secretName="client-cluster-kubeconfig" \
  --set dot-ai.ai.provider=$AI_PROVIDER \
  --set dot-ai.secrets.$SECRET_KEY=$API_KEY \
  --set dot-ai.secrets.auth.token=$SHARED_AUTH_TOKEN \
  --set dot-ai.localEmbeddings.enabled=true \
  --set dot-ai.ingress.enabled=true \
  --set dot-ai.ingress.className=nginx \
  --set dot-ai.ingress.host=dot-ai.$BASE_DOMAIN \
  --set dot-ai.webUI.baseUrl=http://dot-ai-ui.$BASE_DOMAIN \
  --set dot-ai-ui.uiAuth.token=$SHARED_AUTH_TOKEN \
  --set dot-ai-ui.ingress.enabled=true \
  --set dot-ai-ui.ingress.host=dot-ai-ui.$BASE_DOMAIN \
  --wait 2>&1 | tee "$HELM_LOG"

# --- REMOTE SANDBOX PREPARATION ---
echo "----------------------------------------------"
echo "Preparing Remote Sandbox on client-1..."

# 1. Create remote namespace
kubectl create namespace dot-ai --context=kind-client-1 --dry-run=client -o yaml | kubectl apply --context=kind-client-1 -f -

# 2. Migrate CRDs
echo "Migrating CRDs to client-1..."
kubectl get crds --context=kind-dot-ai-stack | grep devopstoolkit.live | awk '{print $1}' | xargs kubectl get crd -o yaml --context=kind-dot-ai-stack > dot-ai-crds.yaml
kubectl apply -f dot-ai-crds.yaml --context=kind-client-1
rm dot-ai-crds.yaml

# 3. Apply Sync Instructions
echo "Applying ResourceSyncConfig rules..."
cat << 'EOF' > sync-rules.yaml
apiVersion: dot-ai.devopstoolkit.live/v1alpha1
kind: ResourceSyncConfig
metadata:
  name: default-sync
  namespace: dot-ai
spec:
  debounceWindowSeconds: 10
  mcpAuthSecretRef:
    key: auth-token
    name: dot-ai-secrets
  mcpEndpoint: http://dot-ai:3456/api/v1/resources/sync
  resyncIntervalMinutes: 60
EOF
kubectl apply -f sync-rules.yaml --context=kind-client-1
rm sync-rules.yaml

# 4. Mirror Secrets
echo "Mirroring Authentication Secrets to client-1..."
kubectl get secret dot-ai-secrets -n dot-ai --context=kind-dot-ai-stack -o yaml > mirrored-secret.yaml
grep -v '^\s*uid:' mirrored-secret.yaml | \
grep -v '^\s*resourceVersion:' | \
grep -v '^\s*creationTimestamp:' | \
grep -v '^\s*generation:' > clean-secret.yaml
kubectl apply -f clean-secret.yaml --context=kind-client-1
rm mirrored-secret.yaml clean-secret.yaml

# 5. Kick the Controller
echo "Restarting Hub controller to initiate remote sync..."
kubectl delete pods -l app.kubernetes.io/name=dot-ai-controller -n dot-ai --context=kind-dot-ai-stack

# --- FINAL OUTPUT ---
echo "----------------------------------------------"
echo "Deployment Complete!"
echo "Access your services at:"
echo "Web UI: http://dot-ai-ui.$BASE_DOMAIN"
echo "MCP Server: http://dot-ai.$BASE_DOMAIN"
echo ""
echo "Important: Your Unified Access Token is: $SHARED_AUTH_TOKEN"
echo "Note: It may take 30-60 seconds for the UI to populate with remote cluster namespaces."