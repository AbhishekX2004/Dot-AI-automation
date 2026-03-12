# Helm Chart Modifications: The "Brain Transplant"

To transform the Dot-AI stack from a single-cluster tool into a Hub-and-Spoke controller, we had to fundamentally change how the core pods (`mcp-server`, `agentic-tools`, and `controller-manager`) view the world.

Instead of rewriting the underlying Golang codebase, we modified the Helm chart to hijack the pods' environment variables and inject a remote `kubeconfig`. 

## 1. `values.yaml` Additions
We added a new configuration block to allow users to specify a remote cluster secret:
```yaml
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
*Result: The controller physically runs on the Hub, but its "brain" is permanently wired to the remote Client API.*