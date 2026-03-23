# Onboard Client Script Breakdown

The `onboard-client.sh` script is the production-grade tool for connecting a remote Kubernetes cluster (EKS, GKE, ACP, or a raw kubeconfig file) to the Dot-AI Hub. This document explains what each section does and why.

> **Related:** For the equivalent local testing script, see [Local Testing Script Breakdown](local-testing-script-breakdown.md).

---

## Section 1 — Validate Configuration

```bash
source "$VARS_FILE"
_require_var CLIENT_ID
_require_var HUB_CONTEXT
_require_var CLOUD_PROVIDER
# ... etc
```

**What it does:** Loads and validates the client vars file (e.g. `acme-corp.vars`). Enforces that `CLIENT_ID` uses only lowercase letters, numbers, and hyphens, and that `CLOUD_PROVIDER` is one of `eks | gke | acp | file`.

**Why:** Catching bad inputs early prevents cryptic Kubernetes errors mid-way through the script. The script uses `set -euo pipefail` so any unvalidated variable access would cause a silent failure.

---

## Section 2 — Fetch Client Kubeconfig

```bash
case "$CLOUD_PROVIDER" in
  eks)  aws eks update-kubeconfig ... ;;
  gke)  gcloud container clusters get-credentials ... ;;
  acp)  # builds a minimal token-based kubeconfig ;;
  file) cp "$KUBECONFIG_FILE" "$TMP_KUBECONFIG" ;;
esac
```

**What it does:** Downloads or constructs a temporary kubeconfig for the client cluster using the appropriate cloud CLI. For `acp`, it hand-builds a minimal kubeconfig using the supplied bearer token. All paths write to a secured temp file (`mktemp`) that is deleted on script exit via `trap`.

**Why:** The Hub controller will ultimately need to talk to this cluster. We fetch the kubeconfig here to verify connectivity before making any changes.

---

## Section 3 — Create a Static Bearer Token (The Authentication Fix)

```bash
kc_client create serviceaccount dot-ai-remote-admin -n "$CLIENT_DOT_AI_NAMESPACE"
kc_client create clusterrolebinding dot-ai-remote-admin-binding \
  --clusterrole=cluster-admin \
  --serviceaccount="${CLIENT_DOT_AI_NAMESPACE}:dot-ai-remote-admin"

CLIENT_TOKEN=$(kc_client create token dot-ai-remote-admin -n "$CLIENT_DOT_AI_NAMESPACE" --duration=87600h)
```

**The Pitfall:** The kubeconfig fetched from `aws eks update-kubeconfig` contains an `exec:` block that calls the AWS CLI to generate a short-lived token. This works on a developer's laptop, but the Hub controller pod running inside Kubernetes does not have the AWS CLI installed. The exec-based kubeconfig silently fails with an auth error the moment the controller tries to use it.

**The Fix:** We create a dedicated `ServiceAccount` (`dot-ai-remote-admin`) on the client cluster with `cluster-admin` permissions, then use the Kubernetes `TokenRequest` API to generate a long-lived, static Bearer Token (requested for 10 years; EKS caps it at 24 hours). This produces a kubeconfig that any standard Kubernetes client library can use without any cloud credentials.

> **Production Note:** For long-running systems, implement a token rotation mechanism or use IRSA-based authentication.

---

## Section 4 — Build a Clean Kubeconfig for the Hub

```bash
cat > "$HUB_SECRET_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: client-cluster
  cluster:
    server: ${CLIENT_SERVER}
    certificate-authority-data: ${CLIENT_CA}
contexts:
- name: client-cluster
  ...
users:
- name: dot-ai-controller
  user:
    token: ${CLIENT_TOKEN}
EOF
```

**What it does:** Constructs a minimal, self-contained kubeconfig containing only the client cluster's API server URL, its CA certificate, and the static Bearer Token from Section 3. If no CA data is present (some providers), it falls back to `insecure-skip-tls-verify: true`.

**Why:** The raw kubeconfig from the cloud CLI often contains extra contexts, named clusters, and exec-plugin references. Injecting that directly into a Kubernetes Secret would confuse the controller. A clean, single-context kubeconfig guarantees the controller always connects to the right cluster.

---

## Section 5 — Prepare Hub Namespace & Inject Secret

```bash
kubectl create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  --from-file=config="$HUB_SECRET_KUBECONFIG" \
  --namespace "$HUB_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**What it does:** Creates a dedicated namespace on the Hub cluster (named after `CLIENT_ID`, e.g. `acme-corp`) and injects the clean kubeconfig as a Kubernetes Secret. The `--dry-run=client -o yaml | kubectl apply -f -` pattern makes the operation **idempotent** — safe to re-run without errors.

**Why:** Each client gets its own namespace on the Hub. Isolating Helm releases, secrets, and ingress rules per namespace prevents one client's configuration from leaking into another.

---

## Section 6 — Deploy the Helm Release

```bash
helm upgrade --install "$HELM_RELEASE" "$HELM_CHART_PATH" \
  --namespace "$HUB_NAMESPACE" \
  --set dot-ai.remoteCluster.secretName="$SECRET_NAME" \
  --set dot-ai-controller.remoteCluster.secretName="$SECRET_NAME" \
  --set dot-ai.ingress.host="dot-ai-${CLIENT_ID}.${BASE_DOMAIN}" \
  --set dot-ai-ui.ingress.host="dot-ai-ui-${CLIENT_ID}.${BASE_DOMAIN}" \
  ...
```

**What it does:** Deploys (or upgrades) a scoped `dot-ai-stack` Helm release into the client's Hub namespace. Key values set:
- `remoteCluster.secretName` — tells the chart where to mount the kubeconfig Secret (the "brain transplant").
- Per-client ingress hostnames like `dot-ai-acme-corp.<BASE_DOMAIN>` for the MCP API and `dot-ai-ui-acme-corp.<BASE_DOMAIN>` for the Web UI.
- A freshly generated auth token shared between the UI and backend.

**Why:** `helm upgrade --install` is idempotent. Re-running the onboarding script (e.g. after updating vars) safely upgrades the existing release instead of failing.

> **See also:** [Helm Chart Modifications](helm-chart-changes.md) for how `remoteCluster.secretName` is wired into the chart templates.

---

## Section 7 — Bootstrap the Client Cluster

This section runs several operations against the **client** cluster (e.g. `acme-corp` EKS), not the Hub.

### 7a. Create the Leader Election Namespace

```bash
kc_client create namespace "$HUB_NAMESPACE" --dry-run=client -o yaml | kc_client apply -f -
```

**The Pitfall:** `error initially creating leader election record: namespaces "acme-corp" not found`

The Hub controller runs in the `acme-corp` namespace on the Hub. Because it is wired to the client cluster via the injected kubeconfig, it tries to create its leader election `Lease` object there too — in a namespace named after the client. If the namespace doesn't exist on the client cluster, the controller crashes in a restart loop.

**The Fix:** We pre-create the `$HUB_NAMESPACE` (i.e., the client's name) on the client cluster before the controller boots.

### 7b. Migrate CRDs

```bash
kubectl get crds --context "$HUB_CONTEXT" | grep devopstoolkit.live | xargs kubectl get crd -o yaml \
  | grep -v 'uid:\|resourceVersion:\|...' \
  > "$CRDS_TEMP"

kc_client apply --server-side --force-conflicts -f "$CRDS_TEMP"
```

**The Pitfall:** `no matches for kind "GitKnowledgeSource"`

Helm installs Dot-AI CRDs only on the Hub. The controller, operating through the client-cluster kubeconfig, tries to read these CRD-defined resources on the client cluster and crashes because the API server doesn't recognize the types.

**The Fix:** We export the CRDs from the Hub and apply them to the client cluster. The `--server-side --force-conflicts` flags handle re-runs gracefully even if CRDs already partially exist.

### 7c. Apply ResourceSyncConfig

```bash
cat > "$SYNC_TEMP" <<EOF
apiVersion: dot-ai.devopstoolkit.live/v1alpha1
kind: ResourceSyncConfig
...
  mcpEndpoint: http://dot-ai.${HUB_NAMESPACE}.svc.cluster.local:3456/api/v1/resources/sync
EOF
kc_client apply -f "$SYNC_TEMP"
```

**What it does:** Creates a `ResourceSyncConfig` CR on the client cluster. This tells the controller which Kubernetes resources to watch and where to send the synced data (the Hub's internal MCP endpoint).

**Why an internal URL:** The endpoint `http://dot-ai.<HUB_NAMESPACE>.svc.cluster.local:3456` is the Kubernetes in-cluster DNS name. Using this avoids NAT hairpinning issues and ensures the controller can always reach the Hub regardless of external DNS configuration.

### 7d. Mirror Authentication Secrets

```bash
kubectl get secret dot-ai-secrets --namespace "$HUB_NAMESPACE" -o yaml \
  | grep -v 'uid:\|resourceVersion:\|...' \
  | sed "s/namespace: ${HUB_NAMESPACE}/namespace: ${CLIENT_DOT_AI_NAMESPACE}/" \
  > "$SECRET_TEMP"

kc_client apply -f "$SECRET_TEMP" --namespace "$CLIENT_DOT_AI_NAMESPACE"
```

**The Pitfall:** `failed to get auth token: auth secret 'dot-ai-secrets' not found`

After successfully scanning the client cluster and building the resource inventory, the controller attempts to authenticate with the Hub's MCP endpoint to push the data. It looks for the `dot-ai-secrets` secret — but on the client cluster. Helm only created this secret on the Hub.

**The Fix:** Mirror the secret from the Hub to the `dot-ai` namespace on the client cluster. The `sed` command rewrites the namespace field so it lands in the correct location.

---

## Section 8 — Restart the Hub Controller

```bash
kubectl delete pods \
  --context "$HUB_CONTEXT" \
  --namespace "$HUB_NAMESPACE" \
  --selector app.kubernetes.io/name=dot-ai-controller \
  --ignore-not-found
```

**What it does:** Deletes the controller pod(s), causing Kubernetes to restart them immediately.

**The Pitfall:** Stateful components like `qdrant` (the vector database) can hold stale data from a previous sync cycle. If the controller boots before all the bootstrapping in Section 7 is complete, it may write partial data. Restarting it after the bootstrap ensures a clean initial sync into an empty database.

**Why `--ignore-not-found`:** Makes the script safe to re-run even if the controller pod was already cycling.

---

## Final Output

At the end, the script prints:

```
  Web UI   : http://dot-ai-ui-<CLIENT_ID>.<BASE_DOMAIN>/dashboard
  MCP API  : http://dot-ai-<CLIENT_ID>.<BASE_DOMAIN>
  Auth Token: <SHARED_AUTH_TOKEN>
```

Open the Web UI URL in a browser and use the Auth Token to log in.
