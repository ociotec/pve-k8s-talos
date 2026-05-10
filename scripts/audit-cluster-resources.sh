#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: audit-cluster-resources.sh --cluster <name> [options]

Audits Kubernetes workload containers for missing or undersized CPU/memory
requests and limits, using Prometheus 24h usage data from the monitoring
prometheus-api ingress.

Run from clusters/<cluster>, for example:
  ../../scripts/audit-cluster-resources.sh --cluster eht

Options:
  --cluster <name>      Cluster name. Must match the current clusters/<name> directory.
  --top <n>             Number of table rows to show. Defaults to 25.
  --all                 Show all rows.
  --section <name>      Limit output to a section. Can be repeated.
                        Known sections: identity, k8s-net, monitoring, platform, rook, other.
  --format <format>     Output format: markdown or json. Defaults to markdown.
  --include-ok          Include containers with no finding. Defaults to false.
  --skip-prometheus     Only audit declared requests/limits; usage columns are n/a.
  -h, --help            Show this help message.

Required tools:
  kubectl, curl, jq

Prometheus credentials:
  Reads prometheus_api_url, prometheus_api_basic_auth_user, and
  prometheus_api_basic_auth_password from:
    clusters/<cluster>/out/monitoring/terraform.tfstate

Safety:
  The password and authenticated URL are never printed.
USAGE
}

cluster_arg=""
top_rows=25
show_all=false
output_format="markdown"
include_ok=false
skip_prometheus=false
sections=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      if [[ $# -lt 2 ]]; then
        error "--cluster requires a value."
        exit 1
      fi
      cluster_arg="$2"
      shift 2
      ;;
    --top)
      if [[ $# -lt 2 ]]; then
        error "--top requires a value."
        exit 1
      fi
      top_rows="$2"
      shift 2
      ;;
    --all)
      show_all=true
      shift
      ;;
    --section)
      if [[ $# -lt 2 ]]; then
        error "--section requires a value."
        exit 1
      fi
      sections+=("$2")
      shift 2
      ;;
    --format)
      if [[ $# -lt 2 ]]; then
        error "--format requires a value."
        exit 1
      fi
      output_format="$2"
      shift 2
      ;;
    --include-ok)
      include_ok=true
      shift
      ;;
    --skip-prometheus)
      skip_prometheus=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

case "${output_format}" in
  markdown|json) ;;
  *)
    error "--format must be markdown or json."
    exit 1
    ;;
esac

if ! [[ "${top_rows}" =~ ^[0-9]+$ ]] || [[ "${top_rows}" -lt 1 ]]; then
  error "--top must be a positive integer."
  exit 1
fi

if [[ "${#sections[@]}" -eq 0 ]]; then
  sections_json="[]"
else
  sections_json="$(printf '%s\n' "${sections[@]}" | jq -R . | jq -s .)"
fi

require_cmd kubectl
require_cmd jq
if [[ "${skip_prometheus}" != "true" ]]; then
  require_cmd curl
fi

setup_cluster_context "${script_dir}" "${cluster_arg}"
require_cluster_file "${cluster_kubeconfig_path}" "cluster kubeconfig"
require_cluster_file "${script_dir}/audit-cluster-resources.jq" "audit jq filter"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cluster-resource-audit.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

workloads_path="${tmp_dir}/workloads.json"
pods_path="${tmp_dir}/pods.json"
replicasets_path="${tmp_dir}/replicasets.json"
cpu_p95_path="${tmp_dir}/prom-cpu-p95.json"
mem_max_path="${tmp_dir}/prom-mem-max.json"
cpu_current_path="${tmp_dir}/prom-cpu-current.json"
mem_current_path="${tmp_dir}/prom-mem-current.json"
cluster_cpu_p95_path="${tmp_dir}/prom-cluster-cpu-p95.json"
cluster_mem_max_path="${tmp_dir}/prom-cluster-mem-max.json"

kubectl --kubeconfig "${cluster_kubeconfig_path}" get deploy,statefulset,daemonset,job,cronjob -A -o json >"${workloads_path}"
kubectl --kubeconfig "${cluster_kubeconfig_path}" get pods -A -o json >"${pods_path}"
kubectl --kubeconfig "${cluster_kubeconfig_path}" get replicasets -A -o json >"${replicasets_path}"

empty_prometheus_result() {
  printf '{"status":"success","data":{"resultType":"vector","result":[]}}\n'
}

query_prometheus() {
  local query="$1"
  local output_path="$2"

  curl -fsS -u "${prometheus_api_user}:${prometheus_api_password}" \
    --get "${prometheus_api_url}/api/v1/query" \
    --data-urlencode "query=${query}" \
    >"${output_path}"
}

if [[ "${skip_prometheus}" == "true" ]]; then
  empty_prometheus_result >"${cpu_p95_path}"
  empty_prometheus_result >"${mem_max_path}"
  empty_prometheus_result >"${cpu_current_path}"
  empty_prometheus_result >"${mem_current_path}"
  empty_prometheus_result >"${cluster_cpu_p95_path}"
  empty_prometheus_result >"${cluster_mem_max_path}"
else
  monitoring_state_path="${cluster_monitoring_workspace}/terraform.tfstate"
  require_cluster_file "${monitoring_state_path}" "monitoring OpenTofu state"

  prometheus_api_url="$(jq -r '.outputs.prometheus_api_url.value // empty' "${monitoring_state_path}")"
  prometheus_api_user="$(jq -r '.outputs.prometheus_api_basic_auth_user.value // empty' "${monitoring_state_path}")"
  prometheus_api_password="$(jq -r '.outputs.prometheus_api_basic_auth_password.value // empty' "${monitoring_state_path}")"

  if [[ -z "${prometheus_api_url}" || -z "${prometheus_api_user}" || -z "${prometheus_api_password}" ]]; then
    error "Missing prometheus-api outputs in ${monitoring_state_path}."
    exit 1
  fi

  query_prometheus \
    'quantile_over_time(0.95, (sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m])))[24h:5m])' \
    "${cpu_p95_path}"
  query_prometheus \
    'max_over_time(container_memory_working_set_bytes{container!="",image!=""}[24h])' \
    "${mem_max_path}"
  query_prometheus \
    'sum(rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m]))' \
    "${cpu_current_path}"
  query_prometheus \
    'sum(container_memory_working_set_bytes{container!="",image!=""})' \
    "${mem_current_path}"
  query_prometheus \
    'quantile_over_time(0.95, (sum(rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m])))[24h:5m])' \
    "${cluster_cpu_p95_path}"
  query_prometheus \
    'max_over_time((sum(container_memory_working_set_bytes{container!="",image!=""}))[24h:5m])' \
    "${cluster_mem_max_path}"
fi

jq -r -n \
  --slurpfile workloads "${workloads_path}" \
  --slurpfile pods "${pods_path}" \
  --slurpfile replicasets "${replicasets_path}" \
  --slurpfile cpu "${cpu_p95_path}" \
  --slurpfile mem "${mem_max_path}" \
  --slurpfile cpuCurrent "${cpu_current_path}" \
  --slurpfile memCurrent "${mem_current_path}" \
  --slurpfile clusterCpu "${cluster_cpu_p95_path}" \
  --slurpfile clusterMem "${cluster_mem_max_path}" \
  --arg cluster "${cluster_name}" \
  --argjson topRows "${top_rows}" \
  --argjson showAll "${show_all}" \
  --arg outputFormat "${output_format}" \
  --argjson includeOk "${include_ok}" \
  --argjson skipPrometheus "${skip_prometheus}" \
  --argjson sections "${sections_json}" \
  -f "${script_dir}/audit-cluster-resources.jq"
