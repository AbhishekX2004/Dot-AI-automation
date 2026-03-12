# DevOps AI Toolkit: Hub-and-Spoke Architecture

This repository provides a fully automated, zero-config local deployment of the Dot-AI DevOps agent in a multi-cluster (Hub-and-Spoke) topology. 

Traditionally, the Dot-AI stack is designed to monitor the cluster it is installed on. By utilizing a "brain transplant" technique via custom Helm chart modifications and automated state migrations, this setup decouples the AI agent (the Hub) from the infrastructure it manages (the Spoke/Client).

## Prerequisites
* Docker
* [Kind](https://kind.sigs.k8s.io/) (Kubernetes IN Docker)
* `kubectl`
* `helm`
* An OpenAI or Anthropic API Key

## Quick Start (The "Two Command" Setup)

**Step 1: Spin up the Client Cluster**
This creates a lightweight `client-1` cluster and deploys a frontend, a backend cache, and a intentionally broken "chaos" pod for the AI to debug.
```bash
./setup-client.sh
```

**Step 2: Deploy the AI Hub**
This creates the `dot-ai-stack` cluster, dynamically extracts the Client's kubeconfig, injects it into the Hub, deploys the modified Helm chart, and automatically handles all cross-cluster state migrations.
```bash
./install-dot-ai-remote.sh
```

## Accessing the Dashboard
Once the installation script completes, navigate to:
* **Web UI:** `http://dot-ai-ui.127.0.0.1.nip.io/dashboard`
* **Login Token:** `testing` (or the token output at the end of the script)

**Test the AI:**
Head to the Chat interface and prompt the agent:
> *"There is a failing API deployment in the chaos-testing namespace. Find out why it is crashing and fix it."*

## Deep Dives
Curious how we tricked a single-cluster tool into managing remote architecture? Read the documentation:
* [Helm Chart Modifications](docs/helm-chart-changes.md) - How we wired the Kubeconfig injection.
* [Architecture & Script Breakdown](docs/script-breakdown.md) - A line-by-line history of the cross-cluster state synchronization and the bugs that forced us to build it.