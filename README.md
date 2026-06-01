<div align="center">

# Kubernetes Wastage Scanner

**Free · Open Source · Zero-install Kubernetes cost savings scanner**

[![GitHub Repo](https://img.shields.io/badge/GitHub-ecoscale%2Fkubernetes--wastage--scanner-blue?logo=github)](https://github.com/ecoscale/kubernetes-wastage-scanner)
[![Stars](https://img.shields.io/github/stars/ecoscale/kubernetes-wastage-scanner?style=social)](https://github.com/ecoscale/kubernetes-wastage-scanner)

**⭐ Star us on GitHub — it helps others find this tool!**

[Website](https://ecoscale.github.io/kubernetes-wastage-scanner/) · [GitHub](https://github.com/ecoscale/kubernetes-wastage-scanner) · [ecoscale.dev](https://ecoscale.dev)

---

</div>

Scan your Kubernetes cluster for idle CPU, memory, and GPU resources — no installation, no agents, no credentials stored. Get a detailed terminal/JSON report with saving recommendations, with an optional publish to [ecoscale.dev](https://ecoscale.dev) for a shareable HTML report (available for 24 hours).

## Quick start

```bash
# Download and run locally (no data leaves your machine)
curl -sSLO https://raw.githubusercontent.com/ecoscale/kubernetes-wastage-scanner/main/scan.sh
chmod +x scan.sh
./scan.sh
```

## Requirements

- `kubectl` configured with a cluster context
- `awk`, `sort`, `head`, `cut`, `tr`, `printf`, `date`, `mktemp`
- `curl` (only needed for `--publish` / publishing reports)

## Usage

```bash
./scan.sh [flags]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--local` | | Print report only, do not publish |
| `--publish=BOOL` | `false` | Enable/disable publishing |
| `--endpoint URL` | `https://ecoscale.dev` | Publish endpoint |
| `--context NAME` | current context | kubectl context to use |
| `--namespace NS` | all namespaces | Restrict scan to a namespace |
| `--top N` | `10` | Top items per table |
| `--output FORMAT` | `table` | Output format: `table` or `json` |
| `--redact=BOOL` | `false` | Redact names in published JSON |
| `--nodepool-label KEY` | auto-detect | Override nodepool label detection |
| `--quiet` | | Suppress progress output |
| `--help` | | Show help |

### Security notes

**Publishing is opt-in (disabled by default).** You must pass `--publish=true` or omit `--local` to send data to an endpoint. For production clusters, review what metadata is sent and consider `--redact=true`.

### Examples

```bash
# Default (local only, no publish) — safe for production
./scan.sh

# Explicitly publish to endpoint
./scan.sh --publish=true --endpoint https://ecoscale.dev/api

# Scan a specific namespace, output JSON
./scan.sh --namespace=kube-system --output=json

# Use a specific kubectl context, show top 20 items
./scan.sh --context=prod-cluster --top=20
```

## What it scans

- **Nodes** – capacity, allocatable resources, nodepool labels (Karpenter, EKS, GKE, AKS)
- **Pods & containers** – resource requests and actual usage (via Metrics Server)
- **ReplicaSets / Jobs** – resolves workloads up to Deployments, Rollouts, and CronJobs

## Output

- **Table output** – terminal-friendly report with overall stats, top wasted namespaces/workloads, overallocated nodes/nodepools, missing resource requests, and GPU allocation
- **JSON output** – structured JSON for programmatic consumption
- **Published HTML** – shareable detailed report hosted for 24 hours

## Limitations

This tool uses **Metrics Server** to collect real-time usage data from your Kubernetes cluster. The Kubernetes Metrics Server has a default metric resolution window of **60 seconds**, though it scrapes data from Kubelets every **15 seconds**. Because this is a point-in-time snapshot with a short sampling window, the report may be incomplete or misleading in some cases — especially for bursty workloads or clusters with frequent pod churn.

## Want deeper analysis?

If you need **historical data**, **predictive recommendations**, and **longer trend analysis**, check out our standalone server setup. It works with popular tools like **Prometheus** to analyze resource utilization over the last **2 weeks** and provides intelligent predictions for your Kubernetes resources.

[📅 Schedule a free demo](https://ecoscale.dev/contact)
