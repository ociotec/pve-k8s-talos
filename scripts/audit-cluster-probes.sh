#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: audit-cluster-probes.sh --cluster <name> [options]

Audits Kubernetes workload containers for readiness, liveness, and startup
probe coverage.

Run from clusters/<cluster>, for example:
  ../../scripts/audit-cluster-probes.sh --cluster eht

Options:
  --cluster <name>      Cluster name. Must match the current clusters/<name> directory.
  --top <n>             Number of table rows to show. Defaults to 25.
  --all                 Show all rows.
  --section <name>      Limit output to a section. Can be repeated.
                        Known sections: identity, k8s-net, monitoring, platform, rook, s3-storage, other.
  --format <format>     Output format: markdown or json. Defaults to markdown.
  --include-ok          Include containers with no readiness/liveness finding. Defaults to false.
  --include-jobs        Include Jobs and CronJobs. Defaults to false.
  -h, --help            Show this help message.

Required tools:
  kubectl, jq
USAGE
}

cluster_arg=""
top_rows=25
show_all=false
output_format="markdown"
include_ok=false
include_jobs=false
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
    --include-jobs)
      include_jobs=true
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

setup_cluster_context "${script_dir}" "${cluster_arg}"
require_cluster_file "${cluster_kubeconfig_path}" "cluster kubeconfig"
require_cluster_file "${script_dir}/audit-cluster-probes.jq" "audit jq filter"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cluster-probe-audit.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

workloads_path="${tmp_dir}/workloads.json"

if [[ "${include_jobs}" == "true" ]]; then
  kubectl --kubeconfig "${cluster_kubeconfig_path}" get deploy,statefulset,daemonset,job,cronjob -A -o json >"${workloads_path}"
else
  kubectl --kubeconfig "${cluster_kubeconfig_path}" get deploy,statefulset,daemonset -A -o json >"${workloads_path}"
fi

jq -r -n \
  --slurpfile workloads "${workloads_path}" \
  --argjson sections "${sections_json}" \
  --argjson includeOk "${include_ok}" \
  --argjson showAll "${show_all}" \
  --argjson topRows "${top_rows}" \
  --arg outputFormat "${output_format}" \
  -f "${script_dir}/audit-cluster-probes.jq"
