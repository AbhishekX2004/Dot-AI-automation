# Local Testing Guide

This directory contains the scripts for running the full Dot-AI Hub-and-Spoke setup locally using **Kind** (Kubernetes IN Docker) clusters — no AWS costs required.

> **Purpose:** Rapid local iteration and development. For real EKS deployments, see the [root README](../README.md).

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (running)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `kubectl`
- `helm`
- `openssl`
- An OpenAI **or** Anthropic API Key

---

## Scripts

| Script | Purpose |
|---|---|
| `setup-client.sh` | Creates the **client** Kind cluster (`client-1`) with demo workloads |
| `install-dot-ai-remote.sh` | Creates the **hub** Kind cluster (`dot-ai-stack`), configures cross-cluster wiring, and deploys the Dot-AI stack via Helm |

---

## Quick Start

### Step 1 — Create the Client Cluster

```bash
cd local_testing/
./setup-client.sh
```

This creates a Kind cluster named `client-1` and populates it with three demo namespaces:

| Namespace | Workload | Purpose |
|---|---|---|
| `client-frontend` | NGINX deployment | Simulates a web front-end |
| `client-backend` | Redis deployment | Simulates a backend cache |
| `chaos-testing` | Broken `node:super-broken-tag-999` deployment | A deliberately broken app for the AI to diagnose |

### Step 2 — Deploy the Hub

```bash
./install-dot-ai-remote.sh
```

The script prompts for:
1. **Cluster mode** — choose `local` → `new` to spin up a fresh `dot-ai-stack` Kind cluster (or `existing` to reuse one).
2. **AI Provider** — `OpenAI` or `Anthropic`.
3. **API Key** — your provider's API key.

It then automatically:
- Extracts the `client-1` internal Docker IP and builds a cross-cluster kubeconfig.
- Injects the kubeconfig as a Kubernetes Secret into the Hub.
- Deploys the full `dot-ai-stack` Helm chart.
- Migrates CRDs and sync configuration to the client cluster.
- Mirrors auth secrets and restarts the Hub controller for a clean sync.

### Step 3 — Access the Dashboard

```
Web UI:   http://dot-ai-ui.127.0.0.1.nip.io/dashboard
MCP API:  http://dot-ai.127.0.0.1.nip.io
```

Use the **Auth Token** printed at the end of the script output to log in.

> It may take **30–60 seconds** after the script completes for the UI to populate with client cluster resources.

---

## How It Works

For a line-by-line breakdown of what `install-dot-ai-remote.sh` does and the pitfalls it solves, see:

- [Local Testing Script Breakdown](../docs/local-testing-script-breakdown.md)

---

## Teardown

```bash
kind delete cluster --name dot-ai-stack
kind delete cluster --name client-1
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Script fails with `'client-1' cluster not found` | `setup-client.sh` wasn't run first | Run `./setup-client.sh` before `install-dot-ai-remote.sh` |
| UI shows no resources after 2+ minutes | Controller didn't sync | `kubectl delete pods -l app.kubernetes.io/name=dot-ai-controller -n dot-ai --context=kind-dot-ai-stack` |
| Port 80/443 already in use | Another process is listening | Stop the conflicting process, then delete and re-create the `dot-ai-stack` cluster |
| Kubeconfig extraction fails | Docker bridge IP changed | Delete both clusters and rerun both scripts |
