# Kubernetes Waste Scanner

Scan your Kubernetes cluster for idle CPU, memory, and GPU resources. Get a detailed terminal/JSON report with saving recommendations, with an optional publish to [ecoscale.dev](https://ecoscale.dev) for a shareable HTML report (available for 24 hours).

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

# Explicitly publish to default endpoint
./scan.sh --publish=true

# Scan a specific namespace, output JSON
./scan.sh --namespace=kube-system --output=json

# Use a specific kubectl context, show top 20 items
./scan.sh --context=prod-cluster --top=20

# Publish with redacted names to custom endpoint
./scan.sh --context=prod-cluster --redact=true --publish=true --endpoint=https://your-internal-endpoint.example.com

# Publish to a custom endpoint
./scan.sh --endpoint https://ecoscale.dev/api
```

## What it scans

- **Nodes** – capacity, allocatable resources, nodepool labels (Karpenter, EKS, GKE, AKS)
- **Pods & containers** – resource requests and actual usage (via Metrics Server)
- **ReplicaSets / Jobs** – resolves workloads up to Deployments, Rollouts, and CronJobs
- **GPU resources** – allocation tracking for `nvidia.com/gpu`

## Output

- **Table output** – terminal-friendly report with overall stats, top wasted namespaces/workloads, overallocated nodes/nodepools, missing resource requests, and GPU allocation
- **JSON output** – structured JSON for programmatic consumption
- **Published HTML** – shareable detailed report hosted for 24 hours
