# Automation Breakdown: Navigating the Pitfalls

The `install-dot-ai-remote.sh` script is the result of resolving cascading state and authentication failures caused by forcing a single-cluster tool into a multi-cluster architecture. Here is a breakdown of the custom automation blocks and the historical context behind them.

### 1. Unified Authentication Tokens
```bash
SHARED_AUTH_TOKEN="testing"
```
**The Pitfall:** The original setup generated two separate secure tokens—one for the UI and one for the Backend. Because the Hub's backend API and UI layer were decoupled, they rejected each other's tokens, resulting in a persistent `401 Unauthorized` error when loading the dashboard. 
**The Fix:** Hardcoding (or securely generating) a single, shared token ensures immediate handshake success between the UI and the MCP server.

### 2. Automated Kubeconfig Extraction
```bash
CLIENT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-1-control-plane)
# ... strips TLS and pushes to Hub as a Secret
```
**The Pitfall:** Local Kind clusters use internal Docker IP addresses that change on every spin-up. Furthermore, remote kubeconfigs often contain TLS certificate authorities that fail when routed through different Docker bridge networks.
**The Fix:** We dynamically grab the container IP, disable strict TLS verification for the local testing environment, and inject it as a Kubernetes Secret into the Hub *before* Helm deploys, ensuring the pods boot with the correct map.

### 3. Remote Sandbox Preparation (Leader Election)
```bash
kubectl create namespace dot-ai --context=kind-client-1
```
**The Pitfall:** `error initially creating leader election record: namespaces "dot-ai" not found`
Because the Controller was wired to the Spoke cluster, it tried to create its leader election lock file (`Lease`) over there. It crashed in a loop because the Client cluster didn't have a `dot-ai` namespace.

### 4. Custom Resource Definition (CRD) Migration
```bash
kubectl get crds --context=kind-dot-ai-stack ... > dot-ai-crds.yaml
kubectl apply -f dot-ai-crds.yaml --context=kind-client-1
```
**The Pitfall:** `no matches for kind "GitKnowledgeSource"`
The Controller woke up looking for its Custom Resources to know what to do. Since Helm only installed those CRDs on the Hub, the Spoke cluster's API rejected the Controller's queries, causing a fatal crash. We extract and mirror the dictionary.

### 5. Applying Sync Instructions & Bridging the Auth Gap
```bash
# ... creates sync-rules.yaml pointing to http://dot-ai:3456...
# ... mirrors dot-ai-secrets from Hub to Client
```
**The Pitfall:** `failed to get auth token: auth secret 'dot-ai-secrets' not found`
Once the Controller successfully scanned the Spoke cluster (finding 300+ resources), it needed to send that data back to the Hub's Qdrant vector database. 
1. We had to give it a stripped-down `ResourceSyncConfig` telling it to route payloads back to the Hub's internal `http://dot-ai:3456` endpoint.
2. It panicked because it couldn't find its password to authenticate with that endpoint. It was looking for the secret on the *Client* cluster. Mirroring the Hub's secret to the Client instantly cleared the blockage and populated the UI.

### 6. The Stateful Finalizer Trap (The Pod Kick)
```bash
kubectl delete pods -l app.kubernetes.io/name=dot-ai-controller -n dot-ai --context=kind-dot-ai-stack
```
**The Pitfall:** Stateful components (like Vector Databases) hold onto "ghost data" if not properly cycled. We delete the controller pods at the very end of the script to force them to wake up, read the newly migrated remote state, and execute a fresh, clean sync loop into the database.