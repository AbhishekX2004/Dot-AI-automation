# Cluster Roles and Security Isolation

A core feature of the Dot-AI Hub-and-Spoke architecture is the **strict enforcement of least-privilege security boundaries**. When the remote `hub` connects to the `client` cluster, it must never use unbounded `cluster-admin` access. Instead, we divide the Hub's capabilities into two distinct, deliberately stripped-down service accounts governed by fine-grained `ClusterRoles`.

These roles are defined in the `clusterRoles/` directory and are automatically applied during the `onboard-client.sh` process.

---

## 1. The Controller Identity (`hub-readonly`)

**File:** `clusterRoles/hub-readonly-role.yaml`  
**Bound to:** `dot-ai-controller-admin` ServiceAccount

The Dot-AI Controller is responsible for discovering all resources existing on the spoke cluster and pushing them to the Hub's Qdrant vector database.

### Permissions:
- **Global Read:** Grants `get, list, watch` across all API groups (`*/*`). The controller must be able to index the entire cluster's topology to make it searchable.
- **Exemption - Sync Status:** Grants `get, update, patch` access exclusively to the `resourcesyncconfigs/status` subresource. The controller cannot mutate actual workloads, but it must be allowed to write the timestamp and health of its last sync loop back to its configuration object.
- **Exemption - Leader Election:** Grants full access to `leases` under `coordination.k8s.io`. This is required by the `controller-runtime` package to prevent split-brain scenarios if multiple controllers launch.

---

## 2. The AI Agent Identity (`dot-ai-agent-role`)

**File:** `clusterRoles/dot-ai-agent-role.yaml`  
**Bound to:** `dot-ai-agent` ServiceAccount

The AI Agent (MCP Server) executes queries and operations on behalf of the user when prompting the AI. This is the highest risk component, so its scope is intentionally constrained.

### Permissions:
- **Core Resource Allowlist:** Explicitly permits `get, list, watch` on safe core (`""`) resources such as `pods`, `services`, `configmaps`, `persistentvolumes`, etc.
- **The Secret Blindfold:** The core `secrets` resource is deliberately omitted from the allowlist. **The AI Agent cannot read Kubernetes Secrets on the client cluster**, effectively neutralizing any risk of prompt-injection leading to credential exfiltration.
- **Non-Core Read-Only:** Grants wildcard `get, list, watch` capabilities across non-core API groups (like `apps`, `networking.k8s.io`, `batch`) to give the AI the context it needs to troubleshoot Deployments, Ingresses, and Jobs.
- **No Mutation:** The agent is completely read-only. It cannot create, edit, or delete workloads on the remote cluster within this configuration, ensuring the tool is safe for exploratory debugging.
