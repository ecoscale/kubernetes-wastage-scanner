#!/usr/bin/env bash
set -u

DEFAULT_ENDPOINT="https://app.ecoscale.dev/api"
DEFAULT_TOP=10
DEFAULT_REDACT=false
DEFAULT_PUBLISH=false
SCAN_TTL_HOURS=24
GPU_RESOURCE_KEY="nvidia.com/gpu"

publish="$DEFAULT_PUBLISH"
endpoint="$DEFAULT_ENDPOINT"
context=""
namespace=""
top_n="$DEFAULT_TOP"
output="table"
redact="$DEFAULT_REDACT"
nodepool_label=""
quiet=false

usage() {
  printf '%s\n' "Ecoscale local wastage scanner"
  printf '%s\n' ""
  printf '%s\n' "Usage: $0 [flags]"
  printf '%s\n' "  --local              Print report only, do not publish"
  printf '%s\n' "  --publish=BOOL       Enable/disable publishing (default: true)"
  printf '%s\n' "  --endpoint URL       Publish endpoint (default: https://app.ecoscale.dev/api)"
  printf '%s\n' "  --context NAME       kubectl context to use"
  printf '%s\n' "  --namespace NS       Restrict scan to namespace"
  printf '%s\n' "  --top N              Top items per table (default: 10)"
  printf '%s\n' "  --output FORMAT      table | json (default: table)"
  printf '%s\n' "  --redact=BOOL        Redact names in published JSON (default: false)"
  printf '%s\n' "  --nodepool-label KEY Override nodepool label detection"
  printf '%s\n' "  --quiet              Suppress progress output"
  printf '%s\n' "  --help               Show help"
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$1" >&2
}

info() {
  if [ "$quiet" != "true" ]; then
    printf '[scanner] %s\n' "$1" >&2
  fi
}

bool_arg() {
  case "$1" in
    true|false) printf '%s\n' "$1" ;;
    *) die "expected true or false, got $1" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) publish="false" ;;
    --publish=*) publish="$(bool_arg "${1#*=}")" ;;
    --publish) shift; publish="$(bool_arg "${1:-}")" ;;
    --endpoint=*) endpoint="${1#*=}" ;;
    --endpoint) shift; endpoint="${1:-}" ;;
    --context=*) context="${1#*=}" ;;
    --context) shift; context="${1:-}" ;;
    --namespace=*) namespace="${1#*=}" ;;
    --namespace) shift; namespace="${1:-}" ;;
    --top=*) top_n="${1#*=}" ;;
    --top) shift; top_n="${1:-}" ;;
    --output=*) output="${1#*=}" ;;
    --output) shift; output="${1:-}" ;;
    --redact=*) redact="$(bool_arg "${1#*=}")" ;;
    --redact) shift; redact="$(bool_arg "${1:-}")" ;;
    --nodepool-label=*) nodepool_label="${1#*=}" ;;
    --nodepool-label) shift; nodepool_label="${1:-}" ;;
    --quiet) quiet=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

case "$output" in table|json) ;; *) die "--output must be table or json" ;; esac
case "$top_n" in ''|*[!0-9]*) die "--top must be a positive integer" ;; esac
[ "$top_n" -gt 0 ] || die "--top must be a positive integer"

if command -v awk >/dev/null 2>&1; then
  AWK_BIN="awk"
else
  die "missing required dependency: awk"
fi

for dep in kubectl sort head cut tr printf date mktemp; do
  command -v "$dep" >/dev/null 2>&1 || die "missing required dependency: $dep"
done

if [ "$publish" = "true" ] && ! command -v curl >/dev/null 2>&1; then
  warn "Publishing requires curl. Report printed locally only."
  publish="false"
fi

tmp_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

kubectl_base=(kubectl)
if [ -n "$context" ]; then
  kubectl_base+=(--context "$context")
fi

ns_args=(-A)
if [ -n "$namespace" ]; then
  ns_args=(-n "$namespace")
fi

cluster_context="$context"
if [ -z "$cluster_context" ]; then
  cluster_context="$("${kubectl_base[@]}" config current-context 2>/dev/null || printf 'unknown')"
fi
info "Using kubectl context: $cluster_context"
if [ -n "$namespace" ]; then
  info "Scanning namespace: $namespace"
else
  info "Scanning all namespaces"
fi

scanned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expires_at="$(date -u -d "$scanned_at + ${SCAN_TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
warnings_file="$tmp_dir/warnings.txt"
: >"$warnings_file"

node_template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .metadata.labels "karpenter.sh/nodepool"}}{{"\t"}}{{index .metadata.labels "karpenter.sh/provisioner-name"}}{{"\t"}}{{index .metadata.labels "eks.amazonaws.com/nodegroup"}}{{"\t"}}{{index .metadata.labels "cloud.google.com/gke-nodepool"}}{{"\t"}}{{index .metadata.labels "agentpool"}}{{"\t"}}{{index .metadata.labels "kubernetes.azure.com/agentpool"}}{{"\t"}}{{.status.allocatable.cpu}}{{"\t"}}{{.status.allocatable.memory}}{{"\t"}}{{index .status.allocatable "nvidia.com/gpu"}}{{"\n"}}{{end}}'
if [ -n "$nodepool_label" ]; then
  node_template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .metadata.labels "'"$nodepool_label"'"}}{{"\t"}}{{index .metadata.labels "karpenter.sh/nodepool"}}{{"\t"}}{{index .metadata.labels "karpenter.sh/provisioner-name"}}{{"\t"}}{{index .metadata.labels "eks.amazonaws.com/nodegroup"}}{{"\t"}}{{index .metadata.labels "cloud.google.com/gke-nodepool"}}{{"\t"}}{{index .metadata.labels "agentpool"}}{{"\t"}}{{index .metadata.labels "kubernetes.azure.com/agentpool"}}{{"\t"}}{{.status.allocatable.cpu}}{{"\t"}}{{.status.allocatable.memory}}{{"\t"}}{{index .status.allocatable "nvidia.com/gpu"}}{{"\n"}}{{end}}'
fi

pod_template='{{range .items}}{{ $ns := .metadata.namespace }}{{ $pod := .metadata.name }}{{ $node := .spec.nodeName }}{{ $phase := .status.phase }}{{ $ownerKind := "StandalonePod" }}{{ $ownerName := .metadata.name }}{{ range .metadata.ownerReferences }}{{ $ownerKind = .kind }}{{ $ownerName = .name }}{{ end }}{{range .spec.containers}}{{$ns}}{{"\t"}}{{$pod}}{{"\t"}}{{$node}}{{"\t"}}{{$phase}}{{"\t"}}{{$ownerKind}}{{"\t"}}{{$ownerName}}{{"\t"}}{{.name}}{{"\t"}}{{with .resources.requests}}{{index . "cpu"}}{{end}}{{"\t"}}{{with .resources.requests}}{{index . "memory"}}{{end}}{{"\t"}}{{with .resources.requests}}{{index . "nvidia.com/gpu"}}{{end}}{{"\n"}}{{end}}{{end}}'
rs_template='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{range .metadata.ownerReferences}}{{.kind}}{{"\t"}}{{.name}}{{else}}{{"\t"}}{{end}}{{"\n"}}{{end}}'
job_template='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{range .metadata.ownerReferences}}{{.kind}}{{"\t"}}{{.name}}{{else}}{{"\t"}}{{end}}{{"\n"}}{{end}}'

info "Collecting nodes..."
"${kubectl_base[@]}" get nodes -o go-template="$node_template" >"$tmp_dir/nodes.raw.tsv" || die "failed to collect nodes"
info "Collecting pods and container requests..."
"${kubectl_base[@]}" get pods "${ns_args[@]}" -o go-template="$pod_template" >"$tmp_dir/pods.raw.tsv" || die "failed to collect pods"
info "Collecting ReplicaSets and Jobs..."
"${kubectl_base[@]}" get rs "${ns_args[@]}" -o go-template="$rs_template" >"$tmp_dir/replicasets.raw.tsv" 2>/dev/null || : >"$tmp_dir/replicasets.raw.tsv"
"${kubectl_base[@]}" get jobs "${ns_args[@]}" -o go-template="$job_template" >"$tmp_dir/jobs.raw.tsv" 2>/dev/null || : >"$tmp_dir/jobs.raw.tsv"

info "Collecting namespaces..."
if [ -n "$namespace" ]; then
  printf '%s\n' "$namespace" >"$tmp_dir/namespaces.raw.tsv"
else
  "${kubectl_base[@]}" get namespaces -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' >"$tmp_dir/namespaces.raw.tsv" 2>/dev/null || : >"$tmp_dir/namespaces.raw.tsv"
fi

info "Collecting Kubernetes version..."
"${kubectl_base[@]}" version --short >"$tmp_dir/version.raw" 2>/dev/null || "${kubectl_base[@]}" version >"$tmp_dir/version.raw" 2>/dev/null || : >"$tmp_dir/version.raw"

info "Collecting Metrics Server data..."
metrics_available=true
if ! "${kubectl_base[@]}" top nodes --no-headers >"$tmp_dir/top_nodes.raw.tsv" 2>/dev/null; then
  printf '%s\n' "Metrics Server unavailable for nodes; node utilization unavailable" >>"$warnings_file"
  metrics_available=false
  : >"$tmp_dir/top_nodes.raw.tsv"
fi
if ! "${kubectl_base[@]}" top pods "${ns_args[@]}" --containers --no-headers >"$tmp_dir/top_pods.raw.tsv" 2>/dev/null; then
  printf '%s\n' "Metrics Server unavailable for pods; workload utilization unavailable" >>"$warnings_file"
  metrics_available=false
  : >"$tmp_dir/top_pods.raw.tsv"
fi
printf '%s\n' "GPU utilization unavailable (Metrics Server does not expose GPU metrics)" >>"$warnings_file"

info "Aggregating resource usage..."
"$AWK_BIN" -v top="$top_n" \
  -v redacted="$redact" \
  -v cluster="$cluster_context" \
  -v scanned="$scanned_at" \
  -v expires="$expires_at" \
  -v metrics_available="$metrics_available" \
  -v report_file="$tmp_dir/report.txt" \
  -v warnings_file="$warnings_file" \
  -v nodes_file="$tmp_dir/nodes.raw.tsv" \
  -v replicasets_file="$tmp_dir/replicasets.raw.tsv" \
  -v jobs_file="$tmp_dir/jobs.raw.tsv" \
  -v top_nodes_file="$tmp_dir/top_nodes.raw.tsv" \
  -v top_pods_file="$tmp_dir/top_pods.raw.tsv" \
  -v pods_file="$tmp_dir/pods.raw.tsv" \
  -v namespaces_file="$tmp_dir/namespaces.raw.tsv" \
  -v version_file="$tmp_dir/version.raw" '
function clean(v) { return (v == "" || v == "<no value>" || v == "<nil>") ? "" : v }
function parse_cpu(v) {
  v=clean(v); if (v=="") return 0
  if (v ~ /n$/) { sub(/n$/, "", v); return int((v + 999999) / 1000000) }
  if (v ~ /u$/) { sub(/u$/, "", v); return int((v + 999) / 1000) }
  if (v ~ /m$/) { sub(/m$/, "", v); return int(v) }
  return int(v * 1000)
}
function parse_mem(v) {
  v=clean(v); if (v=="") return 0
  if (v ~ /Ki$/) { sub(/Ki$/, "", v); return int(v * 1024) }
  if (v ~ /Mi$/) { sub(/Mi$/, "", v); return int(v * 1024 * 1024) }
  if (v ~ /Gi$/) { sub(/Gi$/, "", v); return int(v * 1024 * 1024 * 1024) }
  if (v ~ /Ti$/) { sub(/Ti$/, "", v); return int(v * 1024 * 1024 * 1024 * 1024) }
  if (v ~ /K$/) { sub(/K$/, "", v); return int(v * 1000) }
  if (v ~ /M$/) { sub(/M$/, "", v); return int(v * 1000 * 1000) }
  if (v ~ /G$/) { sub(/G$/, "", v); return int(v * 1000 * 1000 * 1000) }
  return int(v)
}
function parse_gpu(v) { v=clean(v); return v == "" ? 0 : int(v) }
function pct(num, den) { return den > 0 ? (num / den * 100) : 0 }
function eff(req, use) { return req > 0 ? (use / req * 100) : 0 }
function waste(req, use) { return req > use ? req - use : 0 }
function unrequested(req, use) { return req == 0 && use > 0 ? use : 0 }
function fmt_cpu(v) { return v >= 1000 ? sprintf("%.2f cores", v / 1000) : sprintf("%dm", v) }
function fmt_mem(v, u) {
  if (v >= 1099511627776) return sprintf("%.2f TiB", v / 1099511627776)
  if (v >= 1073741824) return sprintf("%.2f GiB", v / 1073741824)
  if (v >= 1048576) return sprintf("%.2f MiB", v / 1048576)
  if (v >= 1024) return sprintf("%.2f KiB", v / 1024)
  return sprintf("%d B", v)
}
function js(s) { s=s ""; gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r/, "\\r", s); gsub(/\n/, "\\n", s); return s }
function red(kind, value, key) {
  if (redacted != "true" || value == "") return value
  key=kind SUBSEP value
  if (!(key in redmap)) redmap[key] = kind "-" ++redcount[kind]
  return redmap[key]
}
function top_key(score, used,   k, best, best_score, have) {
  best=""; best_score=0; have=0
  for (k in score) {
    if (used[k]) continue
    if (!have || score[k] > best_score || (score[k] == best_score && k < best)) {
      best=k; best_score=score[k]; have=1
    }
  }
  return best
}
function resolve_workload(ns, kind, name, pod_name, key) {
  if (kind == "ReplicaSet") {
    key=ns SUBSEP name
    if (rs_owner_kind[key] == "Deployment" || rs_owner_kind[key] == "Rollout") return rs_owner_kind[key] SUBSEP rs_owner_name[key]
  }
  if (kind == "Job") {
    key=ns SUBSEP name
    if (job_owner_kind[key] == "CronJob") return "CronJob" SUBSEP job_owner_name[key]
  }
  if (kind == "Node") return "StandalonePod" SUBSEP pod_name
  if (kind == "") return "StandalonePod" SUBSEP (pod_name != "" ? pod_name : name)
  return kind SUBSEP name
}
function add_scope(scope, c_req, m_req, g_req, c_use, m_use, avail) {
  req_cpu[scope] += c_req; req_mem[scope] += m_req; req_gpu[scope] += g_req
  if (c_req > 0) use_cpu[scope] += c_use
  if (m_req > 0) use_mem[scope] += m_use
  if (avail) usage_available[scope]=1
}
function calc(scope) {
  cpu_waste[scope]=waste(req_cpu[scope], use_cpu[scope]); mem_waste[scope]=waste(req_mem[scope], use_mem[scope])
  cpu_unrequested[scope]=unrequested(req_cpu[scope], use_cpu[scope]); mem_unrequested[scope]=unrequested(req_mem[scope], use_mem[scope])
  cpu_eff[scope]=eff(req_cpu[scope], use_cpu[scope]); mem_eff[scope]=eff(req_mem[scope], use_mem[scope])
}
function cpu_json(scope, cap, comma) {
  printf "%s\"cpu\":{\"capacityMillis\":%d,\"requestsMillis\":%d,\"usageMillis\":%d,\"efficiencyPercent\":%.1f,\"wasteMillis\":%d,\"allocationPercent\":%.1f,\"utilizationPercent\":%.1f,\"unrequestedUsageMillis\":%d,\"utilizationAvailable\":%s}", comma, cap, req_cpu[scope], use_cpu[scope], cpu_eff[scope], cpu_waste[scope], pct(req_cpu[scope], cap), pct(use_cpu[scope], cap), cpu_unrequested[scope], usage_available[scope] ? "true" : "false"
}
function mem_json(scope, cap, comma) {
  printf "%s\"memory\":{\"capacityBytes\":%d,\"requestsBytes\":%d,\"usageBytes\":%d,\"efficiencyPercent\":%.1f,\"wasteBytes\":%d,\"allocationPercent\":%.1f,\"utilizationPercent\":%.1f,\"unrequestedUsageBytes\":%d,\"utilizationAvailable\":%s}", comma, cap, req_mem[scope], use_mem[scope], mem_eff[scope], mem_waste[scope], pct(req_mem[scope], cap), pct(use_mem[scope], cap), mem_unrequested[scope], usage_available[scope] ? "true" : "false"
}
function gpu_json(scope, cap, comma) { printf "%s\"gpu\":{\"capacity\":%d,\"requests\":%d,\"usage\":null,\"allocationPercent\":%.1f,\"utilizationAvailable\":false}", comma, cap, req_gpu[scope], pct(req_gpu[scope], cap) }
function row_score(scope) { return cpu_waste[scope] + (mem_waste[scope] / 1048576) }
BEGIN { FS="\t" }
FILENAME==nodes_file {
  np="unknown"
  for (i=2; i<=NF-3; i++) if (clean($i) != "") { np=$i; break }
  node=$1; nodepool[node]=np; nodes[++node_count]=node; node_seen[node]=1
  cap_cpu_node[node]=parse_cpu($(NF-2)); cap_mem_node[node]=parse_mem($(NF-1)); cap_gpu_node[node]=parse_gpu($NF)
  cap_cpu_all += cap_cpu_node[node]; cap_mem_all += cap_mem_node[node]; cap_gpu_all += cap_gpu_node[node]
  cap_cpu_np[np] += cap_cpu_node[node]; cap_mem_np[np] += cap_mem_node[node]; cap_gpu_np[np] += cap_gpu_node[node]; np_nodes[np]++
  next
}
FILENAME==replicasets_file { rs_owner_kind[$1 SUBSEP $2]=clean($3); rs_owner_name[$1 SUBSEP $2]=clean($4); next }
FILENAME==jobs_file { job_owner_kind[$1 SUBSEP $2]=clean($3); job_owner_name[$1 SUBSEP $2]=clean($4); next }
FILENAME==top_nodes_file { split($0, f, /[[:space:]]+/); top_node_cpu[f[1]]=parse_cpu(f[2]); top_node_mem[f[1]]=parse_mem(f[4]); next }
FILENAME==top_pods_file { split($0, f, /[[:space:]]+/); top_pod_cpu[f[1] SUBSEP f[2] SUBSEP f[3]]=parse_cpu(f[4]); top_pod_mem[f[1] SUBSEP f[2] SUBSEP f[3]]=parse_mem(f[5]); top_seen[f[1] SUBSEP f[2] SUBSEP f[3]]=1; next }
FILENAME==pods_file {
  container_count++; ns=$1; pod=$2; node=$3; phase=$4; owner_kind=clean($5); owner_name=clean($6); container=$7
  if (!(ns in ns_seen)) { ns_seen[ns]=1; namespaces[++namespace_count]=ns }
  pod_key=ns SUBSEP pod; if (!(pod_key in pod_seen)) { pod_seen[pod_key]=1; pod_count++ }
  c_req=parse_cpu($8); m_req=parse_mem($9); g_req=parse_gpu($10)
  c_use=top_pod_cpu[ns SUBSEP pod SUBSEP container]; m_use=top_pod_mem[ns SUBSEP pod SUBSEP container]
  avail=(metrics_available == "true" && ((ns SUBSEP pod SUBSEP container) in top_seen))
  split(resolve_workload(ns, owner_kind, owner_name, pod), wk, SUBSEP); kind=wk[1]; name=wk[2]
  wkey=ns SUBSEP kind SUBSEP name; if (!(wkey in workload_seen)) { workload_seen[wkey]=1; workloads[++workload_count]=wkey; workload_ns[wkey]=ns; workload_kind[wkey]=kind; workload_name[wkey]=name }
  pw=pod_key SUBSEP wkey; if (!(pw in workload_pod_seen)) { workload_pod_seen[pw]=1; workload_pods[wkey]++ }
  ns_workload=ns SUBSEP wkey; if (!(ns_workload in ns_workload_seen)) { ns_workload_seen[ns_workload]=1; ns_workload_count[ns]++ }
  add_scope("all", c_req, m_req, g_req, c_use, m_use, avail)
  add_scope("ns:" ns, c_req, m_req, g_req, c_use, m_use, avail)
  add_scope("wl:" wkey, c_req, m_req, g_req, c_use, m_use, avail)
  add_scope("node:" node, c_req, m_req, g_req, c_use, m_use, avail)
  add_scope("np:" nodepool[node], c_req, m_req, g_req, c_use, m_use, avail)
  if ((c_req == 0 || m_req == 0) && (phase == "Running" || phase == "Pending") && owner_kind != "Node") {
    mk=++missing_count; missing_ns[mk]=ns; missing_kind[mk]=kind; missing_name[mk]=name; missing_container[mk]=container; missing_phase[mk]=phase; missing_cpu_use[mk]=c_use; missing_mem_use[mk]=m_use
    missing_score[mk]=(c_req == 0 ? c_use : 0) + ((m_req == 0 ? m_use : 0) / 1048576)
  }
  next
}
FILENAME==namespaces_file { if (!($1 in ns_seen) && $1 != "") { ns_seen[$1]=1; namespaces[++namespace_count]=$1 } next }
FILENAME==version_file { if ($0 ~ /Server Version:/ || $0 ~ /Server Version/) { sub(/^.*Server Version:[[:space:]]*/, "", $0); kube_version=$0 } next }
END {
  if (kube_version == "") kube_version="unknown"
  for (i=1; i<=node_count; i++) {
    node=nodes[i]; scope="node:" node
    if (top_node_cpu[node] > 0 || top_node_mem[node] > 0) { use_cpu[scope]=top_node_cpu[node]; use_mem[scope]=top_node_mem[node]; usage_available[scope]=1 }
  }
  for (scope in req_cpu) calc(scope)
  calc("all")

  print "═══════════════════════════════════════════════════════" > report_file
  print "  Ecoscale Wastage Scan" >> report_file
  print "═══════════════════════════════════════════════════════" >> report_file
  printf "\nCluster:     %s\nScanned:     %s\nNodes:       %d\nNamespaces:  %d\nWorkloads:   %d\nPods:        %d\n", cluster, scanned, node_count, namespace_count, workload_count, pod_count >> report_file
  print "\n─── Overall ───────────────────────────────────────────" >> report_file
  print "Resource   Capacity       Requests       Usage          Efficiency" >> report_file
  printf "CPU        %-14s %-14s %-14s %.1f%%\n", fmt_cpu(cap_cpu_all), fmt_cpu(req_cpu["all"]), fmt_cpu(use_cpu["all"]), cpu_eff["all"] >> report_file
  printf "Memory     %-14s %-14s %-14s %.1f%%\n", fmt_mem(cap_mem_all), fmt_mem(req_mem["all"]), fmt_mem(use_mem["all"]), mem_eff["all"] >> report_file
  printf "GPU        %-14d %-14d %-14s n/a\n", cap_gpu_all, req_gpu["all"], "n/a" >> report_file

  print "\n─── Top Wasted Namespaces ─────────────────────────────" >> report_file
  print "Namespace                 CPU Waste      Mem Waste      Efficiency" >> report_file
  delete score; delete used; for (ns in ns_seen) { scope="ns:" ns; score[ns]=row_score(scope) }
  for (i=1; i<=top; i++) { ns=top_key(score, used); if (ns == "") break; used[ns]=1; scope="ns:" ns; printf "%-25s %-14s %-14s %.1f%%\n", ns, fmt_cpu(cpu_waste[scope]), fmt_mem(mem_waste[scope]), cpu_eff[scope] >> report_file }

  print "\n─── Top Wasted Workloads ──────────────────────────────" >> report_file
  print "Namespace            Kind            Name                       CPU Waste      Mem Waste      Eff%" >> report_file
  delete score; delete used; for (i=1; i<=workload_count; i++) { wkey=workloads[i]; scope="wl:" wkey; score[wkey]=row_score(scope) }
  for (i=1; i<=top; i++) { wkey=top_key(score, used); if (wkey == "") break; used[wkey]=1; scope="wl:" wkey; printf "%-20s %-15s %-26s %-14s %-14s %.1f%%\n", workload_ns[wkey], workload_kind[wkey], workload_name[wkey], fmt_cpu(cpu_waste[scope]), fmt_mem(mem_waste[scope]), cpu_eff[scope] >> report_file }

  print "\n─── Top Overallocated Nodes ───────────────────────────" >> report_file
  print "Node                      Nodepool                  CPU Alloc%   Mem Alloc%   CPU Eff%" >> report_file
  delete score; delete used; for (i=1; i<=node_count; i++) { node=nodes[i]; scope="node:" node; score[node]=(pct(req_cpu[scope], cap_cpu_node[node]) > pct(req_mem[scope], cap_mem_node[node]) ? pct(req_cpu[scope], cap_cpu_node[node]) : pct(req_mem[scope], cap_mem_node[node])) }
  for (i=1; i<=top; i++) { node=top_key(score, used); if (node == "") break; used[node]=1; scope="node:" node; printf "%-25s %-25s %-12.1f %-12.1f %.1f%%\n", node, nodepool[node], pct(req_cpu[scope], cap_cpu_node[node]), pct(req_mem[scope], cap_mem_node[node]), cpu_eff[scope] >> report_file }

  print "\n─── Top Overallocated Nodepools ───────────────────────" >> report_file
  print "Nodepool                  Nodes   CPU Alloc%   CPU Eff%     Mem Alloc%   Mem Eff%" >> report_file
  delete score; delete used; for (np in np_nodes) { scope="np:" np; score[np]=(pct(req_cpu[scope], cap_cpu_np[np]) > pct(req_mem[scope], cap_mem_np[np]) ? pct(req_cpu[scope], cap_cpu_np[np]) : pct(req_mem[scope], cap_mem_np[np])) }
  for (i=1; i<=top; i++) { np=top_key(score, used); if (np == "") break; used[np]=1; scope="np:" np; printf "%-25s %-7d %-12.1f %-12.1f %-12.1f %.1f%%\n", np, np_nodes[np], pct(req_cpu[scope], cap_cpu_np[np]), cpu_eff[scope], pct(req_mem[scope], cap_mem_np[np]), mem_eff[scope] >> report_file }

  print "\n─── Top Missing Requests ──────────────────────────────" >> report_file
  print "Namespace            Kind            Name                       Container             Phase      CPU Usage      Mem Usage" >> report_file
  delete score; delete used; for (i=1; i<=missing_count; i++) score[i]=missing_score[i]
  if (missing_count == 0) print "none" >> report_file
  for (i=1; i<=top; i++) { m=top_key(score, used); if (m == "") break; used[m]=1; printf "%-20s %-15s %-26s %-21s %-10s %-14s %s\n", missing_ns[m], missing_kind[m], missing_name[m], missing_container[m], missing_phase[m], fmt_cpu(missing_cpu_use[m]), fmt_mem(missing_mem_use[m]) >> report_file }

  print "\n─── GPU Allocation ────────────────────────────────────" >> report_file
  print "Nodepool                  GPU Cap    GPU Req    Alloc%" >> report_file
  delete score; delete used; for (np in np_nodes) { scope="np:" np; score[np]=pct(req_gpu[scope], cap_gpu_np[np]) }
  for (i=1; i<=top; i++) { np=top_key(score, used); if (np == "") break; used[np]=1; scope="np:" np; printf "%-25s %-10d %-10d %.1f%%\n", np, cap_gpu_np[np], req_gpu[scope], pct(req_gpu[scope], cap_gpu_np[np]) >> report_file }

  print "\n─── Warnings ──────────────────────────────────────────" >> report_file
  shown=0; while ((getline line < warnings_file) > 0) { print line >> report_file; shown=1 }
  if (missing_count > 0) { printf "%d (out of %d) containers have missing CPU or memory requests\n", missing_count, container_count >> report_file; shown=1 }
  if (!shown) print "none" >> report_file
  close(warnings_file)

  printf "{\"version\":\"v1\",\"redacted\":%s,\"scannedAt\":\"%s\",", redacted, scanned
  printf "\"cluster\":{\"context\":\"%s\",\"kubernetesVersion\":\"%s\",\"nodeCount\":%d,\"namespaceCount\":%d,\"workloadCount\":%d,\"podCount\":%d},", js(red("cluster", cluster)), js(kube_version), node_count, namespace_count, workload_count, pod_count
  printf "\"overall\":{"; cpu_json("all", cap_cpu_all, ""); mem_json("all", cap_mem_all, ","); gpu_json("all", cap_gpu_all, ","); printf "},"
  printf "\"nodepools\":["; delete score; delete used; for (np in np_nodes) { scope="np:" np; score[np]=row_score(scope) } sep=""; for (i=1; i<=top; i++) { np=top_key(score, used); if (np == "") break; used[np]=1; scope="np:" np; printf "%s{\"name\":\"%s\",\"nodeCount\":%d,", sep, js(red("nodepool", np)), np_nodes[np]; cpu_json(scope, cap_cpu_np[np], ""); mem_json(scope, cap_mem_np[np], ","); gpu_json(scope, cap_gpu_np[np], ","); printf "}"; sep="," } printf "],"
  printf "\"nodes\":["; delete score; delete used; for (i=1; i<=node_count; i++) { node=nodes[i]; scope="node:" node; score[node]=row_score(scope) } sep=""; for (i=1; i<=top; i++) { node=top_key(score, used); if (node == "") break; used[node]=1; scope="node:" node; printf "%s{\"name\":\"%s\",\"nodepool\":\"%s\",", sep, js(red("node", node)), js(red("nodepool", nodepool[node])); cpu_json(scope, cap_cpu_node[node], ""); mem_json(scope, cap_mem_node[node], ","); gpu_json(scope, cap_gpu_node[node], ","); printf "}"; sep="," } printf "],"
  printf "\"namespaces\":["; delete score; delete used; for (ns in ns_seen) { scope="ns:" ns; score[ns]=row_score(scope) } sep=""; for (i=1; i<=top; i++) { ns=top_key(score, used); if (ns == "") break; used[ns]=1; scope="ns:" ns; printf "%s{\"name\":\"%s\",\"workloadCount\":%d,", sep, js(red("namespace", ns)), ns_workload_count[ns]; cpu_json(scope, 0, ""); mem_json(scope, 0, ","); printf "}"; sep="," } printf "],"
  printf "\"workloads\":["; delete score; delete used; for (i=1; i<=workload_count; i++) { wkey=workloads[i]; scope="wl:" wkey; score[wkey]=row_score(scope) } sep=""; for (i=1; i<=top; i++) { wkey=top_key(score, used); if (wkey == "") break; used[wkey]=1; scope="wl:" wkey; printf "%s{\"namespace\":\"%s\",\"kind\":\"%s\",\"name\":\"%s\",\"podCount\":%d,", sep, js(red("namespace", workload_ns[wkey])), js(workload_kind[wkey]), js(red("workload", workload_name[wkey])), workload_pods[wkey]; cpu_json(scope, 0, ""); mem_json(scope, 0, ","); printf "}"; sep="," } printf "],"
  printf "\"warnings\":["; sep=""; while ((getline line < warnings_file) > 0) { printf "%s\"%s\"", sep, js(line); sep="," } if (missing_count > 0) printf "%s\"%d (out of %d) containers have missing CPU or memory requests\"", sep, missing_count, container_count; printf "]}\n"
}
' "$tmp_dir/nodes.raw.tsv" "$tmp_dir/replicasets.raw.tsv" "$tmp_dir/jobs.raw.tsv" "$tmp_dir/top_nodes.raw.tsv" "$tmp_dir/top_pods.raw.tsv" "$tmp_dir/pods.raw.tsv" "$tmp_dir/namespaces.raw.tsv" "$tmp_dir/version.raw" >"$tmp_dir/report.json"

published_url=""
if [ "$publish" = "true" ]; then
  info "Publishing report to $endpoint/api/scans..."
  if response="$(curl -fsS -X POST -H "Content-Type: application/json" --max-time 30 --data-binary "@$tmp_dir/report.json" "$endpoint/api/scans" 2>/dev/null)"; then
    published_url="$(printf '%s\n' "$response" | "$AWK_BIN" -F'"' '/"url"/ { for (i=1; i<=NF; i++) if ($i=="url") { print $(i+2); exit } }')"
    info "Publish complete"
  else
    warn "Publish failed. Report printed locally only."
  fi
fi

if [ "$output" = "json" ]; then
  info "Writing JSON report"
  cat "$tmp_dir/report.json"
else
  info "Rendering terminal report"
  cat "$tmp_dir/report.txt"
  if [ -n "$published_url" ]; then
    printf '\nPublished: %s\n' "$published_url"
    printf 'Expires:   %s\n' "$expires_at"
  fi
fi
info "Done"
