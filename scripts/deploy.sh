#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

# Export TF_VAR_* variables from existing Proxmox env vars, so OpenTofu/Terraform
# picks up the Proxmox credentials automatically.
export TF_VAR_proxmox_endpoint="${TF_VAR_proxmox_endpoint:-${PROXMOX_VE_ENDPOINT:-}}"
export TF_VAR_proxmox_api_token="${TF_VAR_proxmox_api_token:-${PROXMOX_VE_API_TOKEN:-}}"
export TF_VAR_proxmox_insecure="${TF_VAR_proxmox_insecure:-${PROXMOX_VE_INSECURE:-}}"

usage() {
  cat <<'USAGE'
Usage: deploy.sh [options]

Deploys the Talos + Rook Ceph stack. By default it skips the destructive
destroy step and only applies.

Options:
  -d, --destroy             Destroy the cluster first (dangerous).
  -D, --destroy-only        Destroy the cluster and exit (no deployment).
      --purge-external-ceph Purge external Ceph resources managed by this cluster.
                            Can be used alone or combined with --destroy/--destroy-only.
  -v, --verbose             Show all command output (do not silence tofu/kubectl).
  -g, --debug               Enable shell tracing + verbose output (sets TF_LOG=DEBUG).
  -c, --skip-ceph           Skip all Rook Ceph steps (operator, cluster, dashboard, CSI).
  -n, --skip-k8s-net        Skip k8s networking and ingress (k8s-net) steps (ingress, MetalLB, cert-manager).
  -i, --skip-identity       Skip identity services (Keycloak and its database).
  -p, --skip-platform       Skip platform services.
      --skip-portainer      Deprecated alias for --skip-platform.
  -m, --skip-monitoring     Skip monitoring stack (Prometheus, Loki, Grafana).
  -h, --help                Show this help message.

Note:
  This script does not auto-upgrade OpenTofu providers.
  To update provider versions manually, run:
    tofu -chdir=<workspace> init -upgrade
USAGE
}

destroy_first=false
destroy_only=false
purge_external_ceph=false
debug=false
verbose=false
skip_ceph=false
skip_k8s_net=false
skip_identity=false
skip_platform=false
skip_monitoring=false
gen_talos_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--destroy)
      destroy_first=true
      shift
      ;;
    -D|--destroy-only)
      destroy_first=true
      destroy_only=true
      shift
      ;;
    --purge-external-ceph)
      purge_external_ceph=true
      shift
      ;;
    -c|--skip-ceph)
      skip_ceph=true
      shift
      ;;
    -n|--skip-k8s-net)
      skip_k8s_net=true
      shift
      ;;
    -i|--skip-identity)
      skip_identity=true
      shift
      ;;
    -p|--skip-platform|--skip-portainer)
      skip_platform=true
      shift
      ;;
    -m|--skip-monitoring)
      skip_monitoring=true
      shift
      ;;
    -v|--verbose)
      verbose=true
      shift
      ;;
    -g|--debug)
      debug=true
      verbose=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${purge_external_ceph}" == "true" && "${destroy_first}" != "true" ]]; then
  error "--purge-external-ceph requires --destroy or --destroy-only." >&2
  exit 1
fi

setup_cluster_context "${script_dir}" ""

controlplane_vip="$(awk -F'"' '/"controlplane_vip"/ { print $4; exit }' "${cluster_constants_path}")"

if [[ "${skip_ceph}" == "true" ]]; then
  gen_talos_args+=(--skip-ceph)
fi
if [[ "${skip_k8s_net}" == "true" ]]; then
  gen_talos_args+=(--skip-k8s-net)
fi
if [[ "${skip_identity}" == "true" ]]; then
  gen_talos_args+=(--skip-identity)
fi
if [[ "${skip_platform}" == "true" ]]; then
  gen_talos_args+=(--skip-platform)
fi
if [[ "${skip_monitoring}" == "true" ]]; then
  gen_talos_args+=(--skip-monitoring)
fi

if [[ "${debug}" == "true" ]]; then
  # Enable verbose tracing and Terraform debug logging for troubleshooting.
  set -x
  export TF_LOG=DEBUG
fi

purge_cluster_out_dir() {
  rm -rf "${cluster_out_dir}"
}

clear_stale_lock_if_present() {
  local workspace="$1"
  local lock_path="${workspace}/.terraform.tfstate.lock.info"

  if [[ ! -f "${lock_path}" ]]; then
    return 0
  fi

  if pgrep -af "tofu -chdir=${workspace}" >/dev/null 2>&1; then
    error "OpenTofu workspace appears to be locked by a running process: ${workspace}" >&2
    error "If this is unexpected, inspect the process before retrying." >&2
    exit 1
  fi

  message "Removing stale OpenTofu lock in ${workspace}..."
  rm -f "${lock_path}"
}

state_dir_has_state() {
  local state_dir="$1"
  [[ -f "${state_dir}/terraform.tfstate" || -f "${state_dir}/terraform.tfstate.backup" ]]
}

# Helper to run commands, optionally silencing output for normal runs.
run() {
  if [[ "${verbose}" == "true" ]]; then
    "$@"
  else
    "$@" 1>/dev/null
  fi
}

run_gen_talos_assets() {
  if [[ "${verbose}" == "true" ]]; then
    "${script_dir}/gen-talos-assets.sh" --cluster "${cluster_name}" "${gen_talos_args[@]}"
  else
    "${script_dir}/gen-talos-assets.sh" --cluster "${cluster_name}" "${gen_talos_args[@]}" 1>/dev/null
  fi
}

run_tofu_init() {
  local workspace="$1"
  local init_log

  clear_stale_lock_if_present "${workspace}"
  message "Initializing OpenTofu providers in ${workspace}..."
  if [[ "${verbose}" == "true" ]]; then
    tofu -chdir="${workspace}" init
    return 0
  fi

  init_log="$(mktemp)"
  if tofu -chdir="${workspace}" init >"${init_log}" 2>&1; then
    rm -f "${init_log}"
    return 0
  fi

  error "OpenTofu init failed in ${workspace}. Output:" >&2
  cat "${init_log}" >&2
  rm -f "${init_log}"
  return 1
}

prepare_k8s_net_workspace() {
  local workspace="${cluster_k8s_net_workspace}"

  require_cluster_file "${cluster_k8s_net_constants_path}" "k8s-net constants"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/k8s-net/.terraform" ]]; then
    link_into_workspace "${repo_root}/k8s-net/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/k8s-net/main.tf" "${workspace}/main.tf"
  link_into_workspace "${repo_root}/k8s-net/cert-manager.yaml" "${workspace}/cert-manager.yaml"
  link_into_workspace "${repo_root}/k8s-net/ingress-nginx-controller.yaml" "${workspace}/ingress-nginx-controller.yaml"
  link_into_workspace "${repo_root}/k8s-net/metallb-native.yaml" "${workspace}/metallb-native.yaml"
  link_into_workspace "${repo_root}/k8s-net/metallb-pool.yaml" "${workspace}/metallb-pool.yaml"
  link_into_workspace "${repo_root}/k8s-net/metrics-server.yaml" "${workspace}/metrics-server.yaml"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  if [[ -r "${repo_root}/k8s-net/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/k8s-net/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_monitoring_workspace() {
  local workspace="${cluster_monitoring_workspace}"

  require_cluster_file "${cluster_monitoring_constants_path}" "monitoring constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/monitoring/.terraform" ]]; then
    link_into_workspace "${repo_root}/monitoring/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/monitoring/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_monitoring_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  link_into_workspace "${repo_root}/monitoring/namespace.yaml" "${workspace}/namespace.yaml"
  link_into_workspace "${repo_root}/monitoring/prometheus.yaml" "${workspace}/prometheus.yaml"
  link_into_workspace "${repo_root}/monitoring/grafana.yaml" "${workspace}/grafana.yaml"
  link_into_workspace "${repo_root}/monitoring/loki.yaml" "${workspace}/loki.yaml"
  link_into_workspace "${repo_root}/monitoring/promtail.yaml" "${workspace}/promtail.yaml"
  link_into_workspace "${repo_root}/monitoring/kube-state-metrics.yaml" "${workspace}/kube-state-metrics.yaml"
  link_into_workspace "${repo_root}/monitoring/grafana" "${workspace}/grafana"
  if [[ -r "${repo_root}/monitoring/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/monitoring/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_identity_workspace() {
  local workspace="${cluster_identity_workspace}"

  require_cluster_file "${cluster_identity_constants_path}" "identity constants"
  require_cluster_file "${cluster_k8s_net_constants_path}" "k8s-net constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/identity/.terraform" ]]; then
    link_into_workspace "${repo_root}/identity/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/identity/main.tf" "${workspace}/main.tf"
  link_into_workspace "${repo_root}/identity/keycloak.yaml" "${workspace}/keycloak.yaml"
  link_into_workspace "${repo_root}/identity/keycloak-realms-job.yaml" "${workspace}/keycloak-realms-job.yaml"
  link_into_workspace "${repo_root}/identity/keycloak-configure-realms.sh.tftpl" "${workspace}/keycloak-configure-realms.sh.tftpl"
  link_into_workspace "${cluster_identity_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  if [[ -r "${repo_root}/identity/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/identity/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_platform_workspace() {
  local workspace="${cluster_platform_workspace}"

  require_cluster_file "${cluster_platform_constants_path}" "platform constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/platform/.terraform" ]]; then
    link_into_workspace "${repo_root}/platform/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/platform/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_platform_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  link_into_workspace "${repo_root}/platform/portainer.yaml" "${workspace}/portainer.yaml"
  link_into_workspace "${repo_root}/platform/configure-portainer-oauth.sh.tftpl" "${workspace}/configure-portainer-oauth.sh.tftpl"
  link_into_workspace "${repo_root}/platform/rancher.yaml" "${workspace}/rancher.yaml"
  if [[ -r "${repo_root}/platform/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/platform/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_rook_workspaces() {
  local rook_root="${cluster_out_dir}/rook"

  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  mkdir -p "${rook_root}" "${cluster_rook_01_workspace}" "${cluster_rook_02_workspace}" "${cluster_rook_03_workspace}" "${cluster_rook_04_workspace}"
  link_into_workspace "${repo_root}/rook/manifests" "${rook_root}/manifests"
  if [[ -d "${repo_root}/rook/01-crds-common-operator/.terraform" ]]; then
    link_into_workspace "${repo_root}/rook/01-crds-common-operator/.terraform" "${cluster_rook_01_workspace}/.terraform"
  fi
  if [[ -d "${repo_root}/rook/02-cluster/.terraform" ]]; then
    link_into_workspace "${repo_root}/rook/02-cluster/.terraform" "${cluster_rook_02_workspace}/.terraform"
  fi
  if [[ -d "${repo_root}/rook/03-dashboard/.terraform" ]]; then
    link_into_workspace "${repo_root}/rook/03-dashboard/.terraform" "${cluster_rook_03_workspace}/.terraform"
  fi
  if [[ -d "${repo_root}/rook/04-csi/.terraform" ]]; then
    link_into_workspace "${repo_root}/rook/04-csi/.terraform" "${cluster_rook_04_workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/rook/01-crds-common-operator/main.tf" "${cluster_rook_01_workspace}/main.tf"
  link_into_workspace "${repo_root}/rook/02-cluster/main.tf" "${cluster_rook_02_workspace}/main.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${cluster_rook_02_workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${cluster_rook_02_workspace}/k8s_net_constants.tf"
  link_into_workspace "${repo_root}/scripts/pve-ceph-external.sh" "${cluster_rook_02_workspace}/pve-ceph-external.sh"
  link_into_workspace "${repo_root}/rook/03-dashboard/main.tf" "${cluster_rook_03_workspace}/main.tf"
  link_into_workspace "${repo_root}/k8s-net/rook-ceph-dashboard-ingress.yaml" "${cluster_rook_03_workspace}/rook-ceph-dashboard-ingress.yaml"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${cluster_rook_03_workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${cluster_rook_03_workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_certs_dir}" "${cluster_rook_03_workspace}/certs"
  link_into_workspace "${repo_root}/rook/04-csi/main.tf" "${cluster_rook_04_workspace}/main.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${cluster_rook_04_workspace}/ceph_constants.tf"
  if [[ -r "${repo_root}/rook/01-crds-common-operator/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/rook/01-crds-common-operator/.terraform.lock.hcl" "${cluster_rook_01_workspace}/.terraform.lock.hcl"
  fi
  if [[ -r "${repo_root}/rook/02-cluster/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/rook/02-cluster/.terraform.lock.hcl" "${cluster_rook_02_workspace}/.terraform.lock.hcl"
  fi
  if [[ -r "${repo_root}/rook/03-dashboard/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/rook/03-dashboard/.terraform.lock.hcl" "${cluster_rook_03_workspace}/.terraform.lock.hcl"
  fi
  if [[ -r "${repo_root}/rook/04-csi/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/rook/04-csi/.terraform.lock.hcl" "${cluster_rook_04_workspace}/.terraform.lock.hcl"
  fi
}

prepare_root_workspace() {
  mkdir -p "${cluster_out_dir}"
  reset_workspace_file "${cluster_root_workspace}/vms_constants.tf"
  reset_workspace_file "${cluster_root_workspace}/vms_list.tf"
  reset_workspace_file "${cluster_root_workspace}/vms_resources.tf"
  if [[ -d "${repo_root}/.terraform" ]]; then
    link_into_workspace "${repo_root}/.terraform" "${cluster_root_workspace}/.terraform"
  fi
}

URL_FMT_START="\033[1m\033[3m\033[4m"
URL_FMT_END="\033[24m\033[23m\033[22m"
DATA_FMT_START="\033[1m\033[3m"
DATA_FMT_END="\033[23m\033[22m"

message_keycloak_realm_console_line() {
  local line="$1"
  local url

  case "${line}" in
    "    Admin console: "*)
      url="${line#"    Admin console: "}"
      message "    Admin console: ${URL_FMT_START}${url}${URL_FMT_END}"
      ;;
    "    Account URL:   "*)
      url="${line#"    Account URL:   "}"
      message "    Account URL:   ${URL_FMT_START}${url}${URL_FMT_END}"
      ;;
    *)
      message "${line}"
      ;;
  esac
}

wait_for_pods_ready() {
  local namespace="$1"
  local selector_input="${2:-}"
  local timeout="${3:-300s}"
  local pods
  local current
  local selector_arg=()

  if [[ -n "${selector_input}" ]]; then
    selector_arg=(-l "app in (${selector_input})")
  fi

  while true; do
    if ! kubectl get namespace "${namespace}" 1>/dev/null 2>&1; then
      sleep 5
      continue
    fi

    pods="$(kubectl -n "${namespace}" get pods "${selector_arg[@]}" --no-headers 2>/dev/null \
      | awk '$3!="Completed" && $3!="Terminating"{print $1}' \
      | sort)"
    if [[ -z "${pods}" ]]; then
      sleep 5
      continue
    fi

    for pod in ${pods}; do
      kubectl -n "${namespace}" wait --for=condition=Ready "pod/${pod}" --timeout="${timeout}" || true
    done

    sleep 5
    current="$(kubectl -n "${namespace}" get pods "${selector_arg[@]}" --no-headers 2>/dev/null \
      | awk '$3!="Completed" && $3!="Terminating"{print $1}' \
      | sort)"
    if [[ "${current}" == "${pods}" ]]; then
      echo "All matching pods are ready and stable in ${namespace}."
      break
    fi
  done
}

wait_for_cephcluster_ready() {
  local namespace="$1"
  local name="$2"
  local ceph_mode="${3:-internal}"
  local timeout_seconds="${4:-900}"
  local start
  local phase
  local health

  start="$(date +%s)"
  while true; do
    echo -n "."
    phase="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    health="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
    if [[ "${ceph_mode}" == "external" ]]; then
      if [[ "${phase}" == "Connected" && "${health}" != "HEALTH_ERR" && -n "${health}" ]]; then
        echo
        message "CephCluster ${namespace}/${name} is Connected (phase=${phase}, health=${health})."
        break
      fi
    elif [[ "${phase}" == "Ready" && "${health}" == "HEALTH_OK" ]]; then
      echo
      message "CephCluster ${namespace}/${name} is Ready (phase=Ready, health=HEALTH_OK)."
      break
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      echo
      error "Timed out waiting for CephCluster ${namespace}/${name} to become Ready (phase=${phase:-unknown}, health=${health:-unknown})." >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_dashboard_cert() {
  local timeout_seconds="${1:-300}"
  local start

  start="$(date +%s)"
  while true; do
    if kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph config-key get mgr/dashboard/crt 1>/dev/null 2>&1 \
      && kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph config-key get mgr/dashboard/key 1>/dev/null 2>&1; then
      message "Ceph dashboard SSL certificate is available."
      break
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Ceph dashboard SSL certificate to be available." >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_pvcs_bound() {
  local namespace="$1"
  local timeout_seconds="${2:-600}"
  shift 2
  local pvc_names=("$@")
  local start
  local pvc_name
  local phase

  if [[ "${#pvc_names[@]}" -eq 0 ]]; then
    return 0
  fi

  start="$(date +%s)"
  while true; do
    local all_bound=true
    for pvc_name in "${pvc_names[@]}"; do
      phase="$(kubectl -n "${namespace}" get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" != "Bound" ]]; then
        all_bound=false
        break
      fi
    done

    if [[ "${all_bound}" == "true" ]]; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for PVCs in ${namespace} to become Bound." >&2
      kubectl -n "${namespace}" get pvc "${pvc_names[@]}" >&2 || true
      exit 1
    fi

    sleep 5
  done
}

wait_for_deployments_ready() {
  local namespace="$1"
  local timeout="${2:-600s}"
  shift 2
  local deployments=("$@")
  local deployment_name

  for deployment_name in "${deployments[@]}"; do
    kubectl -n "${namespace}" rollout status "deploy/${deployment_name}" --timeout="${timeout}"
  done
}

print_job_failure_context() {
  local namespace="$1"
  local job_name="$2"
  local pod_names
  local pod_name

  error "Job ${namespace}/${job_name} did not complete. Current job state:" >&2
  kubectl -n "${namespace}" get job "${job_name}" -o wide >&2 || true
  error "Pods for job ${namespace}/${job_name}:" >&2
  kubectl -n "${namespace}" get pods -l "job-name=${job_name}" -o wide >&2 || true
  error "Recent ${namespace} events:" >&2
  kubectl -n "${namespace}" get events --sort-by=.lastTimestamp | tail -n 40 >&2 || true

  pod_names="$(kubectl -n "${namespace}" get pods -l "job-name=${job_name}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  for pod_name in ${pod_names}; do
    error "Logs for pod/${pod_name}:" >&2
    kubectl -n "${namespace}" logs "pod/${pod_name}" --tail=200 >&2 || true
    error "Previous logs for pod/${pod_name}:" >&2
    kubectl -n "${namespace}" logs "pod/${pod_name}" --previous --tail=200 >&2 || true
  done
}

wait_for_job_complete() {
  local namespace="$1"
  local job_name="$2"
  local timeout_seconds="${3:-600}"
  local start
  local complete_status
  local failed_status
  local bad_pods

  start="$(date +%s)"
  while true; do
    complete_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "${complete_status}" == "True" ]]; then
      return 0
    fi

    failed_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    bad_pods="$(kubectl -n "${namespace}" get pods -l "job-name=${job_name}" --no-headers 2>/dev/null \
      | awk '$3 ~ /^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull)$/ || ($4 + 0) > 0 { print $1 " (" $3 ", restarts=" $4 ")" }' || true)"
    if [[ "${failed_status}" == "True" || -n "${bad_pods}" ]]; then
      if [[ -n "${bad_pods}" ]]; then
        error "Detected failing pods for job ${namespace}/${job_name}: ${bad_pods}" >&2
      fi
      print_job_failure_context "${namespace}" "${job_name}"
      exit 1
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for job ${namespace}/${job_name} to complete." >&2
      print_job_failure_context "${namespace}" "${job_name}"
      exit 1
    fi

    sleep 5
  done
}

wait_for_service_endpoints() {
  local namespace="$1"
  local timeout_seconds="${2:-600}"
  shift 2
  local service_names=("$@")
  local start
  local service_name
  local addresses

  if [[ "${#service_names[@]}" -eq 0 ]]; then
    return 0
  fi

  start="$(date +%s)"
  while true; do
    local all_ready=true
    for service_name in "${service_names[@]}"; do
      addresses="$(kubectl -n "${namespace}" get endpoints "${service_name}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
      if [[ -z "${addresses}" ]]; then
        all_ready=false
        break
      fi
    done

    if [[ "${all_ready}" == "true" ]]; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for service endpoints in ${namespace} to become ready." >&2
      kubectl -n "${namespace}" get endpoints "${service_names[@]}" >&2 || true
      exit 1
    fi

    sleep 5
  done
}

first_worker_ip() {
  local resources_file="${1:-${cluster_resources_path}}"
  local vms_file="${2:-${cluster_vms_path}}"
  local worker_types

  worker_types="$(
    awk '
      /^[[:space:]]*#/ { next }
      match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/".*/, "", name)
        in_block = 1
        k8s = ""
        next
      }
      in_block && match($0, /k8s_node[[:space:]]*=[[:space:]]*"[^"]+"/) {
        k8s = $0
        sub(/^[^"]*"/, "", k8s)
        sub(/".*/, "", k8s)
      }
      in_block && /}/ {
        if (k8s == "worker") { print name }
        in_block = 0
      }
    ' "${resources_file}" | paste -sd, -
  )"

  awk -v types="${worker_types}" '
    BEGIN { n = split(types, allowed, ",") }
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) { in_block=1; is_worker=0; next }
    in_block && match($0, /type[[:space:]]*=[[:space:]]*"[^"]+"/) {
      t = $0
      sub(/^[^"]*"/, "", t)
      sub(/".*/, "", t)
      for (i = 1; i <= n; i++) {
        if (allowed[i] == t) { is_worker=1 }
      }
    }
    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      if (is_worker) {
        ip = $0
        sub(/^[^"]*"/, "", ip)
        sub(/".*/, "", ip)
        print ip
        exit
      }
      in_block=0
      is_worker=0
    }
    in_block && /}/ { in_block=0; is_worker=0 }
  ' "${vms_file}"
}

first_controlplane_ip() {
  local vms_file="${1:-${cluster_vms_path}}"

  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) { in_block=1; is_controlplane=0; next }
    in_block && match($0, /type[[:space:]]*=[[:space:]]*"[^"]+"/) {
      t = $0
      sub(/^[^"]*"/, "", t)
      sub(/".*/, "", t)
      if (t == "controlplane") { is_controlplane=1 }
    }
    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      if (is_controlplane) {
        ip = $0
        sub(/^[^"]*"/, "", ip)
        sub(/".*/, "", ip)
        print ip
        exit
      }
      in_block=0
      is_controlplane=0
    }
    in_block && /}/ { in_block=0; is_controlplane=0 }
  ' "${vms_file}"
}

wait_for_k8s_api_ready() {
  local endpoint_ip="$1"
  local timeout_seconds="${2:-120}"
  local start

  start="$(date +%s)"
  while true; do
    if curl --silent --show-error --insecure --max-time 5 "https://${endpoint_ip}:6443/readyz" >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Kubernetes API on ${endpoint_ip}:6443 to become ready." >&2
      exit 1
    fi

    sleep 5
  done
}

set_kubeconfig_server() {
  local kubeconfig_path="$1"
  local endpoint_ip="$2"

  kubectl config set-cluster talos --server="https://${endpoint_ip}:6443" --kubeconfig "${kubeconfig_path}" 1>/dev/null
}

disk_by_id_prefix() {
  awk -F'"' '/"disk_by_id_prefix"/ { print $4; exit }' "$1"
}

talos_max_pods() {
  awk -F'"' '/"max_pods"/ { print $4; exit }' "$1"
}

reboot_nodes_with_pending_kubelet_max_pods() {
  local constants_file="${1:-${cluster_constants_path}}"
  local desired_max_pods
  local node_rows
  local pending_count=0
  local pending_nodes=()
  local pending_ips=()
  local idx

  desired_max_pods="$(talos_max_pods "${constants_file}")"
  desired_max_pods="${desired_max_pods#"${desired_max_pods%%[![:space:]]*}"}"
  desired_max_pods="${desired_max_pods%"${desired_max_pods##*[![:space:]]}"}"

  if [[ -z "${desired_max_pods}" ]]; then
    return 0
  fi

  if [[ ! "${desired_max_pods}" =~ ^[0-9]+$ ]]; then
    message "warning: talos.max_pods is not numeric (${desired_max_pods}), skipping pending kubelet check."
    return 0
  fi

  if ! command -v talosctl >/dev/null 2>&1; then
    message "warning: talosctl is not available, skipping automatic reboot for pending kubelet max-pods."
    return 0
  fi

  node_rows="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.addresses[?(@.type=="InternalIP")].address}{"|"}{.status.capacity.pods}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${node_rows}" ]]; then
    message "warning: could not read node pod capacity to validate talos.max_pods propagation."
    return 0
  fi

  while IFS='|' read -r node_name node_ip node_max_pods; do
    if [[ -z "${node_name}" || -z "${node_ip}" || -z "${node_max_pods}" ]]; then
      continue
    fi
    if [[ "${node_max_pods}" != "${desired_max_pods}" ]]; then
      pending_count=$((pending_count + 1))
      pending_nodes+=("${node_name}")
      pending_ips+=("${node_ip}")
    fi
  done <<< "${node_rows}"

  if (( pending_count == 0 )); then
    return 0
  fi

  message "info: rebooting ${pending_count} node(s) to apply kubelet max-pods=${desired_max_pods}: ${pending_nodes[*]}"

  for ((idx=0; idx<pending_count; idx++)); do
    local node_name="${pending_nodes[idx]}"
    local node_ip="${pending_ips[idx]}"
    local verify_start

    if ! talosctl -n "${node_ip}" reboot; then
      error "Failed to trigger reboot on ${node_name} (${node_ip})." >&2
      continue
    fi
    if ! kubectl wait --for=condition=Ready "node/${node_name}" --timeout=20m 1>/dev/null; then
      error "Node ${node_name} did not become Ready within timeout after reboot." >&2
      continue
    fi

    verify_start="$(date +%s)"
    while true; do
      local current_max_pods
      current_max_pods="$(kubectl get node "${node_name}" -o jsonpath='{.status.capacity.pods}' 2>/dev/null || true)"
      if [[ "${current_max_pods}" == "${desired_max_pods}" ]]; then
        break
      fi
      if (( $(date +%s) - verify_start >= 300 )); then
        error "Node ${node_name} is Ready but still reports MAX_PODS=${current_max_pods:-unknown} (expected ${desired_max_pods})." >&2
        break
      fi
      sleep 5
    done
  done
}

validate_disk_by_id_prefix() {
  local worker_ip="$1"
  local prefix="$2"
  local timeout_seconds="${3:-120}"
  local start
  local output

  if [[ -z "${prefix}" ]]; then
    error "Missing vm.disk_by_id_prefix in constants.auto.tfvars." >&2
    exit 1
  fi

  if ! command -v talosctl >/dev/null 2>&1; then
    error "talosctl is required to validate vm.disk_by_id_prefix." >&2
    exit 1
  fi

  start="$(date +%s)"
  while true; do
    if output="$(talosctl -n "${worker_ip}" ls /dev/disk/by-id 2>/dev/null)"; then
      if printf '%s\n' "${output}" | grep -q "${prefix}[0-9]\\+"; then
        return 0
      fi
      error "vm.disk_by_id_prefix (${prefix}) not found on ${worker_ip}." >&2
      error "Fix: run 'talosctl -n ${worker_ip} ls /dev/disk/by-id' and look for ${prefix}0." >&2
      exit 1
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting to validate vm.disk_by_id_prefix on ${worker_ip}." >&2
      error "Fix: ensure Talos is up, then verify /dev/disk/by-id contains ${prefix}0." >&2
      exit 1
    fi
    sleep 5
  done
}

ceph_mode_from_constants() {
  local constants_file="$1"
  local mode

  mode="$(awk -F'"' '/^[[:space:]]*ceph_mode[[:space:]]*=/{print $2; exit}' "${constants_file}")"
  if [[ -z "${mode}" ]]; then
    mode="internal"
  fi
  printf '%s\n' "${mode}"
}

deploy_start="$(start_timer)"
message "Provider upgrades are disabled by default. Update manually when needed: tofu -chdir=<workspace> init -upgrade"
if [[ "${purge_external_ceph}" == "true" ]]; then
  if [[ "$(ceph_mode_from_constants "${cluster_ceph_constants_path}")" != "external" ]]; then
    error "--purge-external-ceph requires ceph_mode = \"external\" in ceph_constants.tf." >&2
    exit 1
  fi
fi
prepare_root_workspace
run_gen_talos_assets
run_tofu_init "${cluster_root_workspace}"
if [[ "${destroy_first}" == "true" ]]; then
  if state_dir_has_state "${cluster_root_workspace}"; then
    message "Regenerating Talos assets required for destroy..."
    run_gen_talos_assets
    run_tofu_init "${cluster_root_workspace}"
    message "Destroying Talos cluster VMs..."
    run tofu -chdir="${cluster_root_workspace}" destroy -auto-approve -refresh=false
    message "Done."
  else
    message "No root OpenTofu state found for cluster ${cluster_name}; skipping tofu destroy."
  fi

  if [[ "${purge_external_ceph}" == "true" ]]; then
    "${script_dir}/purge-external-ceph.sh" \
      --cluster-name "${cluster_name}" \
      --ceph-constants "${cluster_ceph_constants_path}"
  fi

  message "Removing generated cluster runtime workspace at ${cluster_out_dir}..."
  purge_cluster_out_dir

  if [[ "${destroy_only}" == "true" ]]; then
    message "Destroy-only requested; exiting without deploying."
    exit 0
  fi
fi

message "Deploying the Talos cluster ${cluster_name} (PVE VMs creation, Talos cluster initialization, k8s bootstrapping)..."
run_gen_talos_assets
run_tofu_init "${cluster_root_workspace}"
run tofu -chdir="${cluster_root_workspace}" apply -auto-approve

if [[ ! -f "${cluster_talosconfig_path}" ]]; then
  if ! tofu -chdir="${cluster_root_workspace}" output -raw talosconfig > "${cluster_talosconfig_path}" 2>/dev/null; then
    error "Failed to write talosconfig from tofu outputs." >&2
    exit 1
  fi
  chmod 600 "${cluster_talosconfig_path}"
  message "Generated ${cluster_talosconfig_path}"
else
  message "talosconfig already exists at ${cluster_talosconfig_path}, skipping generation"
fi

if [[ ! -f "${cluster_kubeconfig_path}" ]]; then
  if ! tofu -chdir="${cluster_root_workspace}" output -raw kubeconfig > "${cluster_kubeconfig_path}" 2>/dev/null; then
    error "Failed to write kubeconfig from tofu outputs." >&2
    exit 1
  fi
  chmod 600 "${cluster_kubeconfig_path}"
  message "Generated ${cluster_kubeconfig_path}"
else
  message "kubeconfig already exists at ${cluster_kubeconfig_path}, skipping generation"
fi

export TALOSCONFIG="${cluster_talosconfig_path}"
active_kubeconfig_path="${cluster_kubeconfig_path}"
bootstrap_kubeconfig_path=""
if [[ -n "${controlplane_vip}" ]]; then
  primary_controlplane_ip="$(first_controlplane_ip)"
  if [[ -z "${primary_controlplane_ip}" ]]; then
    error "Failed to determine the first controlplane IP from vms.auto.tfvars." >&2
    exit 1
  fi
  bootstrap_kubeconfig_path="$(mktemp)"
  cp "${cluster_kubeconfig_path}" "${bootstrap_kubeconfig_path}"
  chmod 600 "${bootstrap_kubeconfig_path}"
  set_kubeconfig_server "${bootstrap_kubeconfig_path}" "${primary_controlplane_ip}"
  active_kubeconfig_path="${bootstrap_kubeconfig_path}"
fi
export KUBECONFIG="${active_kubeconfig_path}"
worker_ip="$(first_worker_ip)"
if [[ -z "${worker_ip}" ]]; then
  error "Failed to determine the first worker name/IP from vms.auto.tfvars." >&2
  exit 1
fi
prefix_value="$(disk_by_id_prefix "${cluster_constants_path}")"
validate_disk_by_id_prefix "${worker_ip}" "${prefix_value}"
if [[ -n "${controlplane_vip}" ]]; then
  wait_for_k8s_api_ready "${controlplane_vip}" "120"
  set_kubeconfig_server "${cluster_kubeconfig_path}" "${controlplane_vip}"
  active_kubeconfig_path="${cluster_kubeconfig_path}"
  export KUBECONFIG="${active_kubeconfig_path}"
  rm -f "${bootstrap_kubeconfig_path}"
  bootstrap_kubeconfig_path=""
fi
reboot_nodes_with_pending_kubelet_max_pods "${cluster_constants_path}"
message "k8s cluster is up and running. Current nodes:"
"${script_dir}/render-k8s-nodes.sh" --kubeconfig "${active_kubeconfig_path}"

if [[ "${skip_k8s_net}" == "true" ]]; then
  message "Skipping k8s networking and ingress (k8s-net) steps."
else
  prepare_k8s_net_workspace
  message "Deploying k8s networking and ingress (k8s-net)..."
  run_tofu_init "${cluster_k8s_net_workspace}"
  run tofu -chdir="${cluster_k8s_net_workspace}" apply -auto-approve \
    -target=kubernetes_manifest.cert_manager_crds \
    -target=kubernetes_manifest.metallb_native_crds \
    -target=local_file.cert_manager_ca_cert \
    -target=local_file.cert_manager_ca_key \
    -var="skip_ceph=${skip_ceph}"
  tofu -chdir="${cluster_k8s_net_workspace}" apply -auto-approve \
    -var="skip_ceph=${skip_ceph}" 1>/dev/null

fi

if [[ "${skip_ceph}" == "true" ]]; then
  message "Skipping Rook Ceph steps."
else
  prepare_rook_workspaces
  ceph_mode_value="$(ceph_mode_from_constants "${cluster_ceph_constants_path}")"
  ceph_phase="$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${ceph_phase}" == "Ready" ]]; then
    message "Rook Ceph cluster already Ready; skipping operator/cluster apply."
  else
    message "Deploying Rook Ceph operator..."
    run_tofu_init "${cluster_rook_01_workspace}"
    run tofu -chdir="${cluster_rook_01_workspace}" apply -auto-approve
    wait_for_pods_ready "rook-ceph" "rook-ceph-operator" "180s"

    message "Deploying Rook Ceph cluster..."
    run_tofu_init "${cluster_rook_02_workspace}"
    run tofu -chdir="${cluster_rook_02_workspace}" apply -auto-approve
    wait_for_cephcluster_ready "rook-ceph" "rook-ceph" "${ceph_mode_value}" "900"
  fi

  message "Deploying Rook Ceph CSI storage classes..."
  run_tofu_init "${cluster_rook_04_workspace}"
  run tofu -chdir="${cluster_rook_04_workspace}" apply -auto-approve
  if [[ "${ceph_mode_value}" == "external" ]]; then
    message "Restarting Rook Ceph CSI RBD provisioner to reload external Ceph monitor configuration..."
    kubectl -n rook-ceph rollout restart deploy/csi-rbdplugin-provisioner 1>/dev/null
    kubectl -n rook-ceph rollout status deploy/csi-rbdplugin-provisioner --timeout=180s 1>/dev/null
  fi
  kubectl -n rook-ceph get storageclasses.storage.k8s.io
fi

if [[ "${skip_identity}" == "true" ]]; then
  message "Skipping identity services."
else
  prepare_identity_workspace
  message "Deploying identity services..."
  run_tofu_init "${cluster_identity_workspace}"
  message "Refreshing one-shot Keycloak jobs before apply..."
  kubectl -n identity delete job keycloak-bootstrap-admin keycloak-configure-realms --ignore-not-found >/dev/null 2>&1 || true
  run tofu -chdir="${cluster_identity_workspace}" apply -auto-approve
  message "Waiting for identity PVCs, workloads, and endpoints to become ready..."
  wait_for_pvcs_bound "identity" "600" "keycloak-postgres-data"
  wait_for_deployments_ready "identity" "900s" "keycloak-postgres" "keycloak"
  wait_for_service_endpoints "identity" "900" "keycloak-postgres" "keycloak"
  wait_for_job_complete "identity" "keycloak-bootstrap-admin" "300"
  if kubectl -n identity get job/keycloak-configure-realms >/dev/null 2>&1; then
    wait_for_job_complete "identity" "keycloak-configure-realms" "900"
  fi
  keycloak_url="$(tofu -chdir="${cluster_identity_workspace}" output -raw keycloak_url)"
  keycloak_admin_user="$(tofu -chdir="${cluster_identity_workspace}" output -raw keycloak_admin_user)"
  keycloak_admin_password="$(tofu -chdir="${cluster_identity_workspace}" output -raw keycloak_admin_password)"
  keycloak_realm_console_summary="$(tofu -chdir="${cluster_identity_workspace}" output -raw keycloak_realm_console_summary)"
  message "Keycloak URL: ${URL_FMT_START}${keycloak_url}${URL_FMT_END}"
  message "Keycloak admin user: ${DATA_FMT_START}${keycloak_admin_user}${DATA_FMT_END}"
  message "Keycloak admin password: ${DATA_FMT_START}${keycloak_admin_password}${DATA_FMT_END}"
  if [[ -n "${keycloak_realm_console_summary}" ]]; then
    message "Configured Keycloak realms:"
    while IFS= read -r keycloak_realm_console_line; do
      message_keycloak_realm_console_line "${keycloak_realm_console_line}"
    done <<< "${keycloak_realm_console_summary}"
  fi
fi

if [[ "${skip_monitoring}" == "true" ]]; then
  message "Skipping monitoring stack."
else
  prepare_monitoring_workspace
  message "Deploying monitoring stack..."
  run_tofu_init "${cluster_monitoring_workspace}"
  run tofu -chdir="${cluster_monitoring_workspace}" apply -auto-approve
  message "Restarting Grafana to reload provisioned dashboards..."
  kubectl -n monitoring rollout restart deploy/grafana 1>/dev/null
  message "Waiting for monitoring PVCs, workloads, and endpoints to become ready..."
  wait_for_pvcs_bound "monitoring" "600" "grafana-data" "loki-data" "prometheus-data"
  wait_for_deployments_ready "monitoring" "600s" "grafana" "loki" "prometheus" "kube-state-metrics"
  wait_for_service_endpoints "monitoring" "600" "grafana" "loki" "prometheus" "kube-state-metrics"
  grafana_url="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_url)"
  prometheus_url="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw prometheus_url)"
  grafana_user="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_admin_user)"
  grafana_password="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_admin_password)"
  message "Grafana URL: ${URL_FMT_START}${grafana_url}${URL_FMT_END}"
  message "Prometheus URL: ${URL_FMT_START}${prometheus_url}${URL_FMT_END}"
  message "Grafana admin user: ${DATA_FMT_START}${grafana_user}${DATA_FMT_END}"
  message "Grafana admin password: ${DATA_FMT_START}${grafana_password}${DATA_FMT_END}"
fi

if [[ "${skip_platform}" == "true" ]]; then
  message "Skipping platform services."
else
  prepare_platform_workspace
  message "Deploying platform services..."
  run_tofu_init "${cluster_platform_workspace}"
  run tofu -chdir="${cluster_platform_workspace}" apply -auto-approve
  message "Waiting for Portainer PVC, workload, and endpoints to become ready..."
  wait_for_pvcs_bound "portainer" "600" "portainer"
  wait_for_deployments_ready "portainer" "600s" "portainer"
  wait_for_service_endpoints "portainer" "600" "portainer"
  portainer_url="$(tofu -chdir="${cluster_platform_workspace}" output -raw portainer_url)"
  portainer_admin_password="$(tofu -chdir="${cluster_platform_workspace}" output -raw portainer_admin_password)"
  message "Portainer URL: ${URL_FMT_START}${portainer_url}${URL_FMT_END}"
  message "Portainer generated bootstrap admin password: ${DATA_FMT_START}${portainer_admin_password}${DATA_FMT_END}"
  rancher_enabled="$(tofu -chdir="${cluster_platform_workspace}" output -raw rancher_enabled)"
  if [[ "${rancher_enabled}" == "true" ]]; then
    message "Waiting for Rancher workload and endpoints to become ready..."
    wait_for_deployments_ready "cattle-system" "900s" "rancher"
    wait_for_service_endpoints "cattle-system" "900" "rancher"
    rancher_url="$(tofu -chdir="${cluster_platform_workspace}" output -raw rancher_url)"
    rancher_bootstrap_password="$(tofu -chdir="${cluster_platform_workspace}" output -raw rancher_bootstrap_password)"
    message "Rancher URL: ${URL_FMT_START}${rancher_url}${URL_FMT_END}"
    message "Rancher bootstrap password: ${DATA_FMT_START}${rancher_bootstrap_password}${DATA_FMT_END}"
  fi
fi

ceph_mode_value="$(ceph_mode_from_constants "${cluster_ceph_constants_path}")"
if [[ "${skip_ceph}" == "true" || "${skip_k8s_net}" == "true" || "${ceph_mode_value}" == "external" ]]; then
  if [[ "${ceph_mode_value}" == "external" && "${skip_ceph}" != "true" ]]; then
    message "Skipping Rook Ceph dashboard ingress for external Ceph mode."
  fi
  :
else
  message "Deploying Rook Ceph dashboard ingress..."
  run_tofu_init "${cluster_rook_03_workspace}"
  run tofu -chdir="${cluster_rook_03_workspace}" apply -auto-approve
  wait_for_dashboard_cert "300"
  rook_dashboard_url="$(tofu -chdir="${cluster_rook_03_workspace}" output -raw rook_ceph_dashboard_url)"
  message "Rook Ceph dashboard URL: ${URL_FMT_START}${rook_dashboard_url}${URL_FMT_END}"
  dashboard_nodeport=$(kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard-external-https -o jsonpath='{.spec.ports[?(@.name=="dashboard")].nodePort}')
  worker_ip="$(first_worker_ip)"
  message "Rook Ceph Dashboard is also available at ${URL_FMT_START}https://${worker_ip}:${dashboard_nodeport}/${URL_FMT_END}"
  dashboard_password=""
  for _ in {1..12}; do
    if kubectl -n rook-ceph get secret rook-ceph-dashboard-password 1>/dev/null 2>&1; then
      dashboard_password=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 --decode)
      break
    fi
    sleep 5
  done
  if [[ -n "${dashboard_password}" ]]; then
    message "Login with username '${DATA_FMT_START}admin${DATA_FMT_END}' and the following password: ${DATA_FMT_START}${dashboard_password}${DATA_FMT_END}"
  else
    error "Dashboard password secret not found yet. Retry: kubectl -n rook-ceph get secret rook-ceph-dashboard-password"
    exit 1
  fi
fi

message "Cluster deployed successfully in $(render_elapsed "${deploy_start}")."
message ""
message "To use this cluster in future shell sessions with talosctl and kubectl:"
message ""
message "Option 1 - Set environment variables for each session:"
message "  export TALOSCONFIG=\"${cluster_out_dir}/talosconfig\""
message "  export KUBECONFIG=\"${cluster_out_dir}/kubeconfig\""
message ""
if [[ -f "${cluster_envrc_path}" ]]; then
  message "Option 2 - Add to your .envrc file:"
  message "  echo 'export TALOSCONFIG=\"\$PWD/out/talosconfig\"' >> .envrc"
  message "  echo 'export KUBECONFIG=\"\$PWD/out/kubeconfig\"' >> .envrc"
  message "  direnv allow"
fi
