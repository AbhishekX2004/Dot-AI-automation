# Helm Chart Modifications: The "Brain Transplant"

To transform the Dot-AI stack from a single-cluster tool into a Hub-and-Spoke controller, we had to fundamentally change how the core pods (`mcp-server`, `agentic-tools`, and `controller-manager`) view the world.

Instead of rewriting the underlying Golang codebase, we modified the Helm chart to hijack the pods' environment variables and inject a remote `kubeconfig`. 

## 1. `values.yaml` Additions
We added configuration blocks in their respective sub-charts to allow assigning distinct remote cluster secrets:
```yaml
# In dot-ai-controller/values.yaml and dot-ai/values.yaml
remoteCluster:
  secretName: "" # Name of the secret containing the client kubeconfig
```

## 2. Deployment Templates
We updated the deployment manifests for the controller and MCP servers to look for this new variable.

**Volume Mounts:**
We created an isolated volume mount that avoids shadowing the existing `/etc/dot-ai` plugin configurations:
```yaml
volumes:
  {{- if .Values.remoteCluster.secretName }}
  - name: remote-kubeconfig
    secret:
      secretName: {{ .Values.remoteCluster.secretName }}
  {{- end }}

volumeMounts:
  {{- if .Values.remoteCluster.secretName }}
  - name: remote-kubeconfig
    mountPath: "/external-cluster"
    readOnly: true
  {{- end }}
```

**Environment Variables:**
By defining the `KUBECONFIG` environment variable, the standard Kubernetes client libraries inside the Go application automatically default to our mounted file instead of the internal service account:
```yaml
env:
  {{- if .Values.remoteCluster.secretName }}
  - name: KUBECONFIG
    value: "/external-cluster/config"
  {{- end }}
```

*Result: The tools run on the Hub, but their operations interact directly with the remote Client API. By using `dot-ai.remoteCluster.secretName` and `dot-ai-controller.remoteCluster.secretName`, we successfully inject dual identities—a read-only Controller agent and an executing AI agent—seamlessly over Helm.*

## 3. CRD Relocation
Custom Resource Definitions (CRDs) were moved out of the individual chart `templates/` directories into a centralized `crds/` folder at the root of the `dot-ai-stack`. This allows Helm to correctly install and upgrade CRDs before evaluating the templates that rely on them.
Moving the CRD files to the root of the `dot-ai-stack` directory ensures that Helm dosen't give ownership to any specific client

## 4. Dynamic Resource Naming
To support multiple installations and prevent naming collisions, hardcoded resource names in the metadata were updated to be dynamic. This change was applied across both main sub-charts:
- `charts/dot-ai/templates/*`
- `charts/dot-ai-controller/templates/*`

Names are now generated using Helm helper functions, such as:
```yaml
metadata:
  name: {{ .Release.Name }}-{{ include "dot-ai.fullname" . }}
```
This ensures resources are uniquely scoped per release, allowing for safer deployments and easier management.