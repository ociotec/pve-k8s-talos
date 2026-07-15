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
      --purge-credentials   Delete generated cluster credentials and generated internal root CA.
                            Requires --destroy or --destroy-only.
  -v, --verbose             Show all command output (do not silence tofu/kubectl).
  -g, --debug               Enable shell tracing + verbose output (sets TF_LOG=DEBUG).
  -c, --skip-ceph           Skip all Rook Ceph steps (operator, cluster, dashboard, CSI).
  -n, --skip-k8s-net        Skip k8s networking and ingress (k8s-net) steps (ingress, MetalLB, cert-manager).
  -i, --skip-identity       Skip identity services (Keycloak and its database).
  -s, --skip-s3-storage     Skip S3-compatible storage services (Garage).
  -p, --skip-platform       Skip platform services.
      --skip-portainer      Deprecated alias for --skip-platform.
  -k, --skip-kafka          Skip Kafka/Redpanda services.
  -m, --skip-monitoring     Skip monitoring stack (Prometheus, Loki, Grafana, Tempo).
  -b, --skip-benchmark      Skip benchmark workloads.
      --services-only       Skip Talos VM/root apply and deploy Kubernetes services only.
                            Requires existing out/kubeconfig and out/talosconfig.
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
purge_credentials=false
debug=false
verbose=false
skip_ceph=false
skip_k8s_net=false
skip_identity=false
skip_s3_storage=false
skip_platform=false
skip_kafka=false
skip_monitoring=false
skip_benchmark=false
services_only=false
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
    --purge-credentials)
      purge_credentials=true
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
    -s|--skip-s3-storage)
      skip_s3_storage=true
      shift
      ;;
    -p|--skip-platform|--skip-portainer)
      skip_platform=true
      shift
      ;;
    -k|--skip-kafka)
      skip_kafka=true
      shift
      ;;
    -m|--skip-monitoring)
      skip_monitoring=true
      shift
      ;;
    -b|--skip-benchmark)
      skip_benchmark=true
      shift
      ;;
    --services-only)
      services_only=true
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

if [[ "${purge_credentials}" == "true" && "${destroy_first}" != "true" ]]; then
  error "--purge-credentials requires --destroy or --destroy-only." >&2
  exit 1
fi

if [[ "${services_only}" == "true" && "${destroy_first}" == "true" ]]; then
  error "--services-only cannot be combined with --destroy or --destroy-only." >&2
  exit 1
fi

setup_cluster_context "${script_dir}" ""

controlplane_vip="$(awk -F'"' '/"controlplane_vip"/ { print $4; exit }' "${cluster_constants_path}")"

check_integer_cpu_millicores() {
  local paths=("$@")
  local matches

  if [[ "${#paths[@]}" -eq 0 ]]; then
    return 0
  fi

  matches="$(
    grep -RInE --include='*.yaml' --include='*.yml' --include='*.tf' \
      'cpu:[[:space:]]*"?[1-9][0-9]*000m"?' \
      "${paths[@]}" 2>/dev/null || true
  )"

  if [[ -z "${matches}" ]]; then
    return 0
  fi

  error "Found integer CPU quantities written as millicores. Kubernetes normalizes these values and the provider can fail after apply." >&2
  error "Use canonical core values instead: \"1\" instead of \"1000m\", \"2\" instead of \"2000m\". Keep fractional values like 1500m as millicores." >&2
  printf '%s\n' "${matches}" >&2
  exit 1
}

check_integer_gibibyte_mebibytes() {
  local paths=("$@")
  local matches

  if [[ "${#paths[@]}" -eq 0 ]]; then
    return 0
  fi

  matches="$(
    find "${paths[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.tf' \) -exec awk '
      /^[[:space:]]*#/ { next }
      /memory[[:space:]:=]+\"?[0-9]+Mi\"?/ {
        value = $0
        sub(/^.*memory[[:space:]:=]+\"?/, "", value)
        sub(/Mi\"?.*$/, "", value)
        if (value + 0 > 0 && value % 1024 == 0) {
          printf "%s:%d:%s\n", FILENAME, FNR, $0
        }
      }
    ' {} + 2>/dev/null || true
  )"

  if [[ -z "${matches}" ]]; then
    return 0
  fi

  error "Found whole-Gi memory quantities written as Mi. Kubernetes normalizes these values and the provider can fail after apply." >&2
  error "Use canonical Gi values instead: \"1Gi\" instead of \"1024Mi\", \"2Gi\" instead of \"2048Mi\". Keep non-whole values like 1536Mi as Mi." >&2
  printf '%s\n' "${matches}" >&2
  exit 1
}

if [[ "${skip_ceph}" == "true" ]]; then
  gen_talos_args+=(--skip-ceph)
fi
if [[ "${skip_k8s_net}" == "true" ]]; then
  gen_talos_args+=(--skip-k8s-net)
fi
if [[ "${skip_identity}" == "true" ]]; then
  gen_talos_args+=(--skip-identity)
fi
if [[ "${skip_s3_storage}" == "true" ]]; then
  gen_talos_args+=(--skip-s3-storage)
fi
if [[ "${skip_platform}" == "true" ]]; then
  gen_talos_args+=(--skip-platform)
fi
if [[ "${skip_kafka}" == "true" ]]; then
  gen_talos_args+=(--skip-kafka)
fi
if [[ "${skip_monitoring}" == "true" ]]; then
  gen_talos_args+=(--skip-monitoring)
fi
if [[ "${skip_benchmark}" == "true" ]]; then
  gen_talos_args+=(--skip-benchmark)
fi

quantity_check_paths=()
if [[ "${skip_ceph}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/rook")
fi
if [[ "${skip_k8s_net}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/k8s-net")
fi
if [[ "${skip_identity}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/identity")
fi
if [[ "${skip_s3_storage}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/s3-storage")
fi
if [[ "${skip_platform}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/platform")
fi
if [[ "${skip_kafka}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/kafka")
fi
if [[ "${skip_monitoring}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/monitoring")
fi
if [[ "${skip_benchmark}" != "true" ]]; then
  quantity_check_paths+=("${repo_root}/benchmark")
fi
check_integer_cpu_millicores "${quantity_check_paths[@]}"
check_integer_gibibyte_mebibytes "${quantity_check_paths[@]}"

if [[ "${debug}" == "true" ]]; then
  # Enable verbose tracing and Terraform debug logging for troubleshooting.
  set -x
  export TF_LOG=DEBUG
fi

purge_cluster_out_dir() {
  rm -rf "${cluster_out_dir}"
}

tf_string_value() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" -F'"' '$0 ~ "^[[:space:]]*" name "[[:space:]]*=" { print $2; exit }' "${file}" 2>/dev/null || true
}

tf_map_string_value() {
  local file="$1"
  local map_name="$2"
  local key_name="$3"

  awk -v map_name="${map_name}" -v key_name="${key_name}" '
    function brace_delta(line,   tmp, opens, closes) {
      tmp = line
      opens = gsub(/{/, "{", tmp)
      tmp = line
      closes = gsub(/}/, "}", tmp)
      return opens - closes
    }

    /^[[:space:]]*#/ { next }

    {
      line = $0
      if (!in_map && line ~ "^[[:space:]]*\"?" map_name "\"?[[:space:]]*=[[:space:]]*\\{") {
        in_map = 1
        map_depth = brace_delta(line)
        if (map_depth <= 0) {
          map_depth = 1
        }
        next
      }

      if (in_map) {
        if (match(line, "\"?" key_name "\"?[[:space:]]*=[[:space:]]*\"[^\"]*\"")) {
          value = substr(line, RSTART, RLENGTH)
          sub(/^[^=]*=[[:space:]]*"/, "", value)
          sub(/".*/, "", value)
          print value
          exit
        }

        map_depth += brace_delta(line)
        if (map_depth <= 0) {
          in_map = 0
          map_depth = 0
        }
      }
    }
  ' "${file}" 2>/dev/null || true
}

resolve_cluster_path() {
  local raw_path="$1"

  case "${raw_path}" in
    "")
      printf ""
      ;;
    /*)
      printf "%s" "${raw_path}"
      ;;
    *)
      printf "%s/%s" "${cluster_dir}" "${raw_path#./}"
      ;;
  esac
}

purge_cluster_credentials() {
  local tls_source
  local root_ca_crt_raw
  local root_ca_key_raw
  local root_ca_crt_path
  local root_ca_key_path

  message "Removing generated cluster credentials..."
  rm -f "${cluster_credentials_path}"

  if [[ ! -r "${cluster_k8s_net_constants_path}" ]]; then
    return 0
  fi

  tls_source="$(tf_string_value "${cluster_k8s_net_constants_path}" tls_source)"
  if [[ "${tls_source:-ca_issuer}" != "ca_issuer" ]]; then
    return 0
  fi

  root_ca_crt_raw="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_crt)"
  root_ca_key_raw="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_key)"
  if [[ -z "${root_ca_crt_raw}" || -z "${root_ca_key_raw}" ]]; then
    return 0
  fi

  root_ca_crt_path="$(resolve_cluster_path "${root_ca_crt_raw}")"
  root_ca_key_path="$(resolve_cluster_path "${root_ca_key_raw}")"
  rm -f "${root_ca_crt_path}" "${root_ca_key_path}"
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

hydrate_workspace_providers_from_cluster_cache() {
  local workspace="$1"
  local target_providers="${workspace}/.terraform/providers"
  local candidate
  local copied=false

  if [[ ! -d "${cluster_out_dir}" ]]; then
    return 1
  fi

  mkdir -p "${target_providers}"
  while IFS= read -r candidate; do
    if [[ "${candidate}" == "${target_providers}" ]]; then
      continue
    fi

    cp -a "${candidate}/." "${target_providers}/"
    copied=true
  done < <(find "${cluster_out_dir}" -path '*/.terraform/providers' -type d 2>/dev/null | sort)

  [[ "${copied}" == "true" ]]
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

run_ensure_credentials() {
  if [[ "${verbose}" == "true" ]]; then
    "${script_dir}/ensure-credentials.sh" --cluster "${cluster_name}"
  else
    "${script_dir}/ensure-credentials.sh" --cluster "${cluster_name}" 1>/dev/null
  fi
}

write_credentials_and_urls_report() {
  local report_path="${cluster_credentials_report_path}"

  mkdir -p "${cluster_secrets_dir}"
  message "Writing service URLs and credentials report to ${report_path}..."
  if ! "${script_dir}/urls-and-credentials.sh" --markdown > "${report_path}"; then
    error "Failed to write service URLs and credentials report." >&2
    exit 1
  fi
  chmod 600 "${report_path}"
}

run_tofu_init() {
  local workspace="$1"
  local init_log
  local retry_log

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

  if grep -qE 'registry\.opentofu\.org|Failed to resolve provider packages' "${init_log}" &&
    hydrate_workspace_providers_from_cluster_cache "${workspace}"; then
    message "Retrying OpenTofu init in ${workspace} with cluster-local cached providers..."
    retry_log="$(mktemp)"
    if tofu -chdir="${workspace}" init >"${retry_log}" 2>&1; then
      rm -f "${init_log}" "${retry_log}"
      return 0
    fi

    error "OpenTofu init retry failed in ${workspace}. Output:" >&2
    cat "${retry_log}" >&2
    rm -f "${retry_log}"
  fi

  error "OpenTofu init failed in ${workspace}. Output:" >&2
  cat "${init_log}" >&2
  rm -f "${init_log}"
  return 1
}

secondary_network_enabled() {
  local bridge_device

  bridge_device="$(tf_map_string_value "${cluster_constants_path}" "network2" "bridge_device")"
  [[ -n "${bridge_device}" ]]
}

root_apply_args() {
  if secondary_network_enabled; then
    printf '%s\n' "-parallelism=1"
  fi
}

collect_workers_with_secondary_network() {
  awk '
    function brace_delta(line,   raw, opens, closes) {
      raw = line
      gsub(/#.*/, "", raw)
      opens = gsub(/{/, "{", raw)
      closes = gsub(/}/, "}", raw)
      return opens - closes
    }

    /^[[:space:]]*#/ { next }

    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      block_depth = brace_delta($0)
      if (block_depth <= 0) {
        block_depth = 1
      }
      node_name = ""
      vm_id = ""
      vm_type = ""
      ip = ""
      ip2 = ""
      next
    }

    in_block && match($0, /node_name[[:space:]]*=[[:space:]]*"[^"]+"/) {
      node_name = $0
      sub(/^[^"]*"/, "", node_name)
      sub(/".*/, "", node_name)
      next
    }

    in_block && match($0, /vm_id[[:space:]]*=[[:space:]]*[0-9]+/) {
      vm_id = $0
      sub(/^[^=]*=[[:space:]]*/, "", vm_id)
      gsub(/[[:space:]]/, "", vm_id)
      next
    }

    in_block && match($0, /type[[:space:]]*=[[:space:]]*"[^"]+"/) {
      vm_type = $0
      sub(/^[^"]*"/, "", vm_type)
      sub(/".*/, "", vm_type)
      next
    }

    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      ip = $0
      sub(/^[^"]*"/, "", ip)
      sub(/".*/, "", ip)
      next
    }

    in_block && match($0, /ip2[[:space:]]*=[[:space:]]*"[^"]+"/) {
      ip2 = $0
      sub(/^[^"]*"/, "", ip2)
      sub(/".*/, "", ip2)
      next
    }

    in_block {
      block_depth += brace_delta($0)
      if (block_depth <= 0) {
        if (vm_type ~ /^worker/ && node_name != "" && vm_id != "" && ip != "" && ip2 != "") {
          print name "|" node_name "|" vm_id "|" ip "|" ip2
        }
        in_block = 0
        block_depth = 0
      }
    }
  ' "${cluster_vms_path}" | sort
}

proxmox_api_base() {
  local base="${TF_VAR_proxmox_endpoint:-${PROXMOX_VE_ENDPOINT:-}}"

  if [[ -z "${base}" ]]; then
    error "Missing Proxmox API endpoint in environment." >&2
    exit 1
  fi

  case "${base%/}" in
    */api2/json)
      printf '%s' "${base%/}"
      ;;
    *)
      printf '%s/api2/json' "${base%/}"
      ;;
  esac
}

proxmox_api_request() {
  local method="$1"
  local path="$2"
  local base
  local insecure_flag="${TF_VAR_proxmox_insecure:-${PROXMOX_VE_INSECURE:-false}}"
  local token="${TF_VAR_proxmox_api_token:-${PROXMOX_VE_API_TOKEN:-}}"
  local -a curl_args

  if [[ -z "${token}" ]]; then
    error "Missing Proxmox API token in environment." >&2
    exit 1
  fi

  base="$(proxmox_api_base)"
  curl_args=(-sS -X "${method}" -H "Authorization: PVEAPIToken=${token}")
  if [[ "${insecure_flag}" == "true" ]]; then
    curl_args=(-sk -X "${method}" -H "Authorization: PVEAPIToken=${token}")
  fi

  curl "${curl_args[@]}" "${base}${path}"
}

wait_for_proxmox_task_completion() {
  local node_name="$1"
  local upid="$2"
  local timeout_seconds="${3:-300}"
  local start
  local task_json
  local status
  local exitstatus

  start="$(date +%s)"
  while true; do
    task_json="$(proxmox_api_request GET "/nodes/${node_name}/tasks/${upid}/status")"
    status="$(printf '%s' "${task_json}" | jq -r '.data.status // empty')"
    exitstatus="$(printf '%s' "${task_json}" | jq -r '.data.exitstatus // empty')"

    if [[ "${status}" == "stopped" ]]; then
      if [[ -n "${exitstatus}" && "${exitstatus}" != "OK" ]]; then
        error "Proxmox task ${upid} on ${node_name} failed: ${exitstatus}" >&2
        exit 1
      fi
      return 0
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Proxmox task ${upid} on ${node_name}." >&2
      exit 1
    fi
    sleep 5
  done
}

talos_boot_id() {
  local node_ip="$1"

  talosctl --talosconfig "${cluster_talosconfig_path}" -n "${node_ip}" read /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n'
}

node_has_persistent_machineconfig() {
  local node_ip="$1"
  talosctl --talosconfig "${cluster_talosconfig_path}" -n "${node_ip}" get machineconfig persistent 1>/dev/null 2>&1
}

node_has_secondary_ip_active() {
  local node_ip="$1"
  local ip2="$2"

  talosctl --talosconfig "${cluster_talosconfig_path}" -n "${node_ip}" get addresses -o yaml 2>/dev/null | grep -q "${ip2}/"
}

node_primary_default_route_ok() {
  local node_ip="$1"

  talosctl --talosconfig "${cluster_talosconfig_path}" -n "${node_ip}" get routespecs -o yaml 2>/dev/null | grep -q 'outLinkName: eth0'
}

secondary_network_machineconfig_path() {
  local worker_name="$1"
  printf '%s/machineconfig-%s.yaml' "${cluster_root_workspace}" "${worker_name}"
}

wait_for_node_ready() {
  local node_name="$1"
  local timeout_seconds="${2:-600}"
  local start
  local ready

  start="$(date +%s)"
  while true; do
    ready="$(kubectl get node "${node_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" == "True" ]]; then
      return 0
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for ${node_name} to become Ready." >&2
      exit 1
    fi
    sleep 5
  done
}

reset_vm_via_proxmox() {
  local node_name="$1"
  local vm_id="$2"
  local response
  local upid

  message "Resetting VM ${vm_id} on ${node_name} to activate staged Talos config..."
  response="$(proxmox_api_request POST "/nodes/${node_name}/qemu/${vm_id}/status/reset")"
  upid="$(printf '%s' "${response}" | jq -r '.data // empty')"
  if [[ -z "${upid}" ]]; then
    error "Failed to start Proxmox reset task for VM ${vm_id} on ${node_name}." >&2
    exit 1
  fi
  wait_for_proxmox_task_completion "${node_name}" "${upid}"
}

stage_secondary_network_worker_configs() {
  local worker_lines=()
  local line
  local worker_name
  local pve_node_name
  local vm_id
  local worker_ip
  local worker_ip2
  local machineconfig_path
  local start

  if ! secondary_network_enabled; then
    return 0
  fi

  mapfile -t worker_lines < <(collect_workers_with_secondary_network)
  if [[ "${#worker_lines[@]}" -eq 0 ]]; then
    return 0
  fi

  require_cmd talosctl

  message "Staging secondary-network Talos config on workers..."
  for line in "${worker_lines[@]}"; do
    IFS='|' read -r worker_name pve_node_name vm_id worker_ip worker_ip2 <<<"${line}"

    if ! node_has_persistent_machineconfig "${worker_ip}"; then
      if node_has_secondary_ip_active "${worker_ip}" "${worker_ip2}" && node_primary_default_route_ok "${worker_ip}"; then
        message "${worker_name} already has the secondary IP active; skipping config stage."
        continue
      fi
    fi

    if node_has_persistent_machineconfig "${worker_ip}"; then
      message "${worker_name} already has staged Talos config; skipping config stage."
      continue
    fi

    machineconfig_path="$(secondary_network_machineconfig_path "${worker_name}")"
    if [[ ! -f "${machineconfig_path}" ]]; then
      error "Missing rendered machineconfig for ${worker_name}: ${machineconfig_path}" >&2
      exit 1
    fi

    talosctl --talosconfig "${cluster_talosconfig_path}" \
      -n "${worker_ip}" \
      apply-config \
      --mode staged \
      --file "${machineconfig_path}" 1>/dev/null

    start="$(date +%s)"
    until node_has_persistent_machineconfig "${worker_ip}"; do
      if (( $(date +%s) - start >= 120 )); then
        error "Timed out waiting for ${worker_name} to accept the staged secondary-network machineconfig." >&2
        exit 1
      fi
      sleep 5
    done
  done
}

reconcile_secondary_network_workers() {
  local worker_lines=()
  local line
  local worker_name
  local pve_node_name
  local vm_id
  local worker_ip
  local worker_ip2
  local boot_id_before
  local boot_id_after
  local start

  if ! secondary_network_enabled; then
    return 0
  fi

  mapfile -t worker_lines < <(collect_workers_with_secondary_network)
  if [[ "${#worker_lines[@]}" -eq 0 ]]; then
    return 0
  fi

  require_cmd jq
  require_cmd curl
  require_cmd talosctl
  require_cmd kubectl

  message "Reconciling staged secondary-network config on workers..."
  for line in "${worker_lines[@]}"; do
    IFS='|' read -r worker_name pve_node_name vm_id worker_ip worker_ip2 <<<"${line}"

    if ! node_has_persistent_machineconfig "${worker_ip}"; then
      if node_has_secondary_ip_active "${worker_ip}" "${worker_ip2}" && node_primary_default_route_ok "${worker_ip}"; then
        message "${worker_name} already has the secondary IP active; skipping."
        continue
      fi

      error "${worker_name} does not have a staged machineconfig and the secondary IP ${worker_ip2} is not active." >&2
      error "Refusing to continue because the node is in an unexpected state." >&2
      exit 1
    fi

    boot_id_before="$(talos_boot_id "${worker_ip}")"
    if [[ -z "${boot_id_before}" ]]; then
      error "Failed to read boot ID from ${worker_name} before reset." >&2
      exit 1
    fi

    reset_vm_via_proxmox "${pve_node_name}" "${vm_id}"

    start="$(date +%s)"
    while true; do
      boot_id_after="$(talos_boot_id "${worker_ip}")"
      if [[ -n "${boot_id_after}" && "${boot_id_after}" != "${boot_id_before}" ]]; then
        break
      fi
      if (( $(date +%s) - start >= 600 )); then
        error "Timed out waiting for ${worker_name} to reboot after staged secondary-network reset." >&2
        exit 1
      fi
      sleep 5
    done

    start="$(date +%s)"
    while node_has_persistent_machineconfig "${worker_ip}"; do
      if (( $(date +%s) - start >= 600 )); then
        error "Timed out waiting for ${worker_name} to promote staged machineconfig." >&2
        exit 1
      fi
      sleep 5
    done

    start="$(date +%s)"
    while true; do
      if node_has_secondary_ip_active "${worker_ip}" "${worker_ip2}" && node_primary_default_route_ok "${worker_ip}"; then
        break
      fi
      if (( $(date +%s) - start >= 600 )); then
        error "Timed out waiting for ${worker_name} to activate ${worker_ip2} on the secondary interface." >&2
        exit 1
      fi
      sleep 5
    done

    wait_for_node_ready "${worker_name}" 600
    message "${worker_name} recovered with ${worker_ip2} active on the secondary interface."
  done
}

current_section=""
section_start=""

start_deploy_section() {
  local section_name="$1"

  current_section="${section_name}"
  section_start="$(start_timer)"
  message "Starting section: ${section_name}."
}

finish_deploy_section() {
  local section_name="$1"
  local status="${2:-completed}"

  message "Section ${section_name} ${status} in $(render_elapsed "${section_start}") (total elapsed: $(render_elapsed "${deploy_start}"))."
  current_section=""
  section_start=""
}

report_current_section_failure() {
  local exit_code="$?"

  set +e
  if [[ -n "${current_section}" && -n "${section_start}" ]]; then
    error "Section ${current_section} failed after $(render_elapsed "${section_start}") (total elapsed: $(render_elapsed "${deploy_start}"))." >&2
  fi
  exit "${exit_code}"
}

kubernetes_resource_version() {
  local namespace="$1"
  local resource_type="$2"
  local resource_name="$3"
  local resource_version

  resource_version="$(
    kubectl -n "${namespace}" get "${resource_type}" "${resource_name}" \
      -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true
  )"
  printf "%s" "${resource_version}"
}

kubernetes_configmap_key_sha256() {
  local namespace="$1"
  local configmap_name="$2"
  local key="$3"
  local content

  content="$(
    kubectl -n "${namespace}" get configmap "${configmap_name}" \
      -o "go-template={{ index .data \"${key}\" }}" 2>/dev/null || true
  )"
  if [[ -z "${content}" ]]; then
    printf ""
    return 0
  fi

  printf "%s" "${content}" | sha256sum | awk '{ print $1 }'
}

kubernetes_resource_changed() {
  local before="$1"
  local after="$2"

  [[ -n "${before}" && -n "${after}" && "${before}" != "${after}" ]]
}

wait_for_prometheus_config_hash() {
  local expected_hash="$1"
  local timeout_seconds="$2"
  local start
  local pod
  local mounted_hash

  start="$(date +%s)"
  while true; do
    pod="$(
      kubectl -n monitoring get pods -l app=prometheus \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"
    if [[ -n "${pod}" ]]; then
      mounted_hash="$(
        kubectl -n monitoring exec "${pod}" -- sha256sum /etc/prometheus/prometheus.yml 2>/dev/null \
          | awk '{ print $1 }' || true
      )"
      if [[ "${mounted_hash}" == "${expected_hash}" ]]; then
        return 0
      fi
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Prometheus to observe the updated ConfigMap." >&2
      return 1
    fi
    sleep 5
  done
}

reload_prometheus_config() {
  kubectl -n monitoring exec deploy/prometheus -- sh -ec 'kill -HUP 1' 1>/dev/null
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
  require_cluster_file "${cluster_credentials_path}" "cluster credentials"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/monitoring/.terraform" ]]; then
    link_into_workspace "${repo_root}/monitoring/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/monitoring/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_constants_path}" "${workspace}/constants.auto.tfvars"
  link_into_workspace "${cluster_monitoring_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_vms_path}" "${workspace}/vms.auto.tfvars"
  link_into_workspace "${cluster_resources_path}" "${workspace}/resources.auto.tfvars"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_credentials_path}" "${workspace}/credentials.json"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  link_into_workspace "${repo_root}/monitoring/namespace.yaml" "${workspace}/namespace.yaml"
  link_into_workspace "${repo_root}/monitoring/prometheus.yaml" "${workspace}/prometheus.yaml"
  link_into_workspace "${repo_root}/monitoring/prometheus-api.yaml" "${workspace}/prometheus-api.yaml"
  link_into_workspace "${repo_root}/monitoring/prometheus-oauth2-proxy.yaml" "${workspace}/prometheus-oauth2-proxy.yaml"
  link_into_workspace "${repo_root}/monitoring/grafana.yaml" "${workspace}/grafana.yaml"
  link_into_workspace "${repo_root}/monitoring/loki.yaml" "${workspace}/loki.yaml"
  link_into_workspace "${repo_root}/monitoring/tempo.yaml" "${workspace}/tempo.yaml"
  link_into_workspace "${repo_root}/monitoring/promtail.yaml" "${workspace}/promtail.yaml"
  link_into_workspace "${repo_root}/monitoring/kube-state-metrics.yaml" "${workspace}/kube-state-metrics.yaml"
  link_into_workspace "${repo_root}/monitoring/node-exporter.yaml" "${workspace}/node-exporter.yaml"
  link_into_workspace "${repo_root}/monitoring/grafana" "${workspace}/grafana"
  link_into_workspace "${repo_root}/monitoring/scripts" "${workspace}/scripts"
  if [[ -r "${repo_root}/monitoring/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/monitoring/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_identity_workspace() {
  local workspace="${cluster_identity_workspace}"

  require_cluster_file "${cluster_identity_constants_path}" "identity constants"
  require_cluster_file "${cluster_k8s_net_constants_path}" "k8s-net constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  require_cluster_file "${cluster_credentials_path}" "cluster credentials"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/identity/.terraform" ]]; then
    link_into_workspace "${repo_root}/identity/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/identity/main.tf" "${workspace}/main.tf"
  link_into_workspace "${repo_root}/identity/keycloak.yaml" "${workspace}/keycloak.yaml"
  link_into_workspace "${cluster_identity_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_credentials_path}" "${workspace}/credentials.json"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  if [[ -r "${repo_root}/identity/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/identity/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_identity_config_workspace() {
  local workspace="${cluster_identity_config_workspace}"

  mkdir -p "${workspace}"
  if [[ -d "${repo_root}/identity-config/.terraform" ]]; then
    link_into_workspace "${repo_root}/identity-config/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/identity-config/main.tf" "${workspace}/main.tf"
  link_into_workspace "${repo_root}/identity-config/configure-keycloak-realms.sh" "${workspace}/configure-keycloak-realms.sh"
  if [[ -r "${repo_root}/identity-config/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/identity-config/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_platform_workspace() {
  local workspace="${cluster_platform_workspace}"

  require_cluster_file "${cluster_platform_constants_path}" "platform constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  require_cluster_file "${cluster_credentials_path}" "cluster credentials"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/platform/.terraform" ]]; then
    link_into_workspace "${repo_root}/platform/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/platform/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_platform_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  link_into_workspace "${cluster_credentials_path}" "${workspace}/credentials.json"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  link_into_workspace "${repo_root}/platform/portainer.yaml" "${workspace}/portainer.yaml"
  link_into_workspace "${repo_root}/platform/configure-portainer-oauth.sh.tftpl" "${workspace}/configure-portainer-oauth.sh.tftpl"
  link_into_workspace "${repo_root}/platform/rancher.yaml" "${workspace}/rancher.yaml"
  if [[ -r "${repo_root}/platform/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/platform/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_s3_storage_workspace() {
  local workspace="${cluster_s3_storage_workspace}"

  require_cluster_file "${cluster_s3_storage_constants_path}" "S3 storage constants"
  require_cluster_file "${cluster_k8s_net_constants_path}" "k8s-net constants"
  require_cluster_file "${cluster_credentials_path}" "cluster credentials"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/s3-storage/.terraform" ]]; then
    link_into_workspace "${repo_root}/s3-storage/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/s3-storage/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_s3_storage_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_vms_path}" "${workspace}/vms.auto.tfvars"
  link_into_workspace "${cluster_resources_path}" "${workspace}/resources.auto.tfvars"
  link_into_workspace "${cluster_credentials_path}" "${workspace}/credentials.json"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  if [[ -r "${repo_root}/s3-storage/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/s3-storage/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_kafka_workspace() {
  local workspace="${cluster_kafka_workspace}"

  require_cluster_file "${cluster_kafka_constants_path}" "Kafka constants"
  require_cluster_file "${cluster_k8s_net_constants_path}" "k8s-net constants"
  require_cluster_file "${cluster_credentials_path}" "cluster credentials"
  mkdir -p "${workspace}" "${cluster_certs_dir}"
  if [[ -d "${repo_root}/kafka/.terraform" ]]; then
    link_into_workspace "${repo_root}/kafka/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/kafka/main.tf" "${workspace}/main.tf"
  link_into_workspace "${repo_root}/kafka/redpanda.yaml" "${workspace}/redpanda.yaml"
  link_into_workspace "${cluster_kafka_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_k8s_net_constants_path}" "${workspace}/k8s_net_constants.tf"
  link_into_workspace "${cluster_vms_path}" "${workspace}/vms.auto.tfvars"
  link_into_workspace "${cluster_resources_path}" "${workspace}/resources.auto.tfvars"
  link_into_workspace "${cluster_credentials_path}" "${workspace}/credentials.json"
  link_into_workspace "${cluster_certs_dir}" "${workspace}/certs"
  if [[ -r "${repo_root}/kafka/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/kafka/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
  fi
}

prepare_benchmark_workspace() {
  local workspace="${cluster_benchmark_workspace}"

  require_cluster_file "${cluster_benchmark_constants_path}" "benchmark constants"
  require_cluster_file "${cluster_ceph_constants_path}" "ceph constants"
  mkdir -p "${workspace}"
  if [[ -d "${repo_root}/benchmark/.terraform" ]]; then
    link_into_workspace "${repo_root}/benchmark/.terraform" "${workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/benchmark/main.tf" "${workspace}/main.tf"
  link_into_workspace "${cluster_benchmark_constants_path}" "${workspace}/constants.tf"
  link_into_workspace "${cluster_ceph_constants_path}" "${workspace}/ceph_constants.tf"
  if [[ -r "${repo_root}/benchmark/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/benchmark/.terraform.lock.hcl" "${workspace}/.terraform.lock.hcl"
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
  local connected

  start="$(date +%s)"
  while true; do
    echo -n "."
    phase="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    health="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
    if [[ "${ceph_mode}" == "external" ]]; then
      connected="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.conditions[?(@.type=="Connected")].status}' 2>/dev/null || true)"
      if [[ "${connected}" == "True" && "${health}" != "HEALTH_ERR" && -n "${health}" ]]; then
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

clear_rook_operator_restart_annotation() {
  if kubectl -n rook-ceph get deploy/rook-ceph-operator 1>/dev/null 2>&1; then
    kubectl -n rook-ceph patch deploy/rook-ceph-operator \
      --type=merge \
      -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":null}}}}}' \
      1>/dev/null 2>&1 || true
  fi
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
    wait_for_rollout_ready "${namespace}" "deploy/${deployment_name}" "${timeout}"
  done
}

wait_for_daemonsets_ready() {
  local namespace="$1"
  local timeout="${2:-600s}"
  shift 2
  local daemonsets=("$@")
  local daemonset_name

  for daemonset_name in "${daemonsets[@]}"; do
    wait_for_rollout_ready "${namespace}" "daemonset/${daemonset_name}" "${timeout}"
  done
}

wait_for_rollout_ready() {
  local namespace="$1"
  local resource="$2"
  local timeout="${3:-600s}"
  local output

  if output="$(kubectl -n "${namespace}" rollout status "${resource}" --timeout="${timeout}" 2>&1)"; then
    if [[ "${verbose}" == "true" && -n "${output}" ]]; then
      printf '%s\n' "${output}"
    fi
    return 0
  fi

  if printf '%s\n' "${output}" | grep -q 'watch ended with error'; then
    message "warning: Kubernetes watch ended while waiting for ${namespace}/${resource}; checking rollout state once more."
    if output="$(kubectl -n "${namespace}" rollout status "${resource}" --timeout=30s 2>&1)"; then
      if [[ "${verbose}" == "true" && -n "${output}" ]]; then
        printf '%s\n' "${output}"
      fi
      return 0
    fi
  fi

  if [[ "${resource}" == deploy/* ]] && printf '%s\n' "${output}" | grep -q 'exceeded its progress deadline'; then
    message "warning: ${namespace}/${resource} reported progress deadline exceeded; waiting for current deployment state once more."
    if kubectl -n "${namespace}" wait --for=condition=Available "${resource}" --timeout="${timeout}" 1>/dev/null 2>&1 \
      && output="$(kubectl -n "${namespace}" rollout status "${resource}" --timeout=30s 2>&1)"; then
      if [[ "${verbose}" == "true" && -n "${output}" ]]; then
        printf '%s\n' "${output}"
      fi
      return 0
    fi
  fi

  error "Rollout failed or timed out for ${namespace}/${resource}." >&2
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
  fi
  exit 1
}

wait_for_resource_existence() {
  local namespace="$1"
  local resource="$2"
  local timeout_seconds="${3:-120}"
  local start

  start="$(date +%s)"
  while true; do
    if kubectl -n "${namespace}" get "${resource}" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for ${namespace}/${resource} to exist." >&2
      return 1
    fi
    sleep 5
  done
}

check_rollout_status() {
  local namespace="$1"
  local resource="$2"
  local timeout="${3:-120s}"

  if kubectl -n "${namespace}" rollout status "${resource}" --timeout="${timeout}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
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
  local now
  local elapsed
  local last_progress
  local printed_wait_status
  local printed_dots
  local complete_status
  local failed_status
  local bad_pods
  local active_status
  local ready_status
  local succeeded_status
  local pod_summary
  local recent_logs

  start="$(date +%s)"
  last_progress=0
  printed_wait_status=false
  printed_dots=false
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    complete_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "${complete_status}" == "True" ]]; then
      if [[ "${printed_dots}" == "true" ]]; then
        printf '\n'
      fi
      message "Job ${namespace}/${job_name} completed."
      return 0
    fi

    failed_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    bad_pods="$(kubectl -n "${namespace}" get pods -l "job-name=${job_name}" --no-headers 2>/dev/null \
      | awk '$3 ~ /^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|Failed)$/ { print $1 " (" $3 ", restarts=" $4 ")" }' || true)"
    if [[ "${failed_status}" == "True" || -n "${bad_pods}" ]]; then
      if [[ -n "${bad_pods}" ]]; then
        error "Detected failing pods for job ${namespace}/${job_name}: ${bad_pods}" >&2
      fi
      print_job_failure_context "${namespace}" "${job_name}"
      exit 1
    fi

    if (( elapsed >= timeout_seconds )); then
      if [[ "${printed_dots}" == "true" ]]; then
        printf '\n'
      fi
      error "Timed out waiting for job ${namespace}/${job_name} to complete." >&2
      print_job_failure_context "${namespace}" "${job_name}"
      exit 1
    fi

    if [[ "${printed_wait_status}" != "true" ]]; then
      active_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.active}' 2>/dev/null || true)"
      ready_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.ready}' 2>/dev/null || true)"
      succeeded_status="$(kubectl -n "${namespace}" get job "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
      pod_summary="$(kubectl -n "${namespace}" get pods -l "job-name=${job_name}" --no-headers 2>/dev/null | awk '{ print $1 ":" $3 ":restarts=" $4 }' | paste -sd ', ' - || true)"
      if [[ "${printed_dots}" == "true" ]]; then
        printf '\n'
      fi
      message "Waiting for job ${namespace}/${job_name} (timeout ${timeout_seconds}s): active=${active_status:-0} ready=${ready_status:-0} succeeded=${succeeded_status:-0}; pods=${pod_summary:-none}"
      printed_wait_status=true
      last_progress="${elapsed}"
    elif (( elapsed - last_progress >= 30 )); then
      recent_logs="$(kubectl -n "${namespace}" logs "job/${job_name}" --since=31s --tail=20 2>/dev/null || true)"
      if [[ -n "${recent_logs}" ]]; then
        printf '\n'
        printf '%s\n' "${recent_logs}" | sed 's/^/  /'
      fi
      last_progress="${elapsed}"
    else
      printf '.'
      printed_dots=true
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

cluster_node_ips() {
  local vms_file="${1:-${cluster_vms_path}}"

  awk '
    /^[[:space:]]*#/ { next }
    match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      ip = $0
      sub(/^[^"]*"/, "", ip)
      sub(/".*/, "", ip)
      print ip
    }
  ' "${vms_file}"
}

append_no_proxy_entry() {
  local entry="$1"
  local current

  if [[ -z "${entry}" ]]; then
    return 0
  fi

  current="${NO_PROXY:-${no_proxy:-}}"
  case ",${current}," in
    *",${entry},"*)
      ;;
    *)
      if [[ -z "${current}" ]]; then
        current="${entry}"
      else
        current="${current},${entry}"
      fi
      export NO_PROXY="${current}"
      export no_proxy="${current}"
      ;;
  esac
}

configure_local_cluster_no_proxy() {
  local ip

  append_no_proxy_entry "localhost"
  append_no_proxy_entry "127.0.0.1"
  append_no_proxy_entry "::1"
  append_no_proxy_entry "${controlplane_vip}"
  while IFS= read -r ip; do
    append_no_proxy_entry "${ip}"
  done < <(cluster_node_ips)
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

talos_kubernetes_version() {
  awk -F'"' '/"kubernetes_version"/ { print $4; exit }' "$1"
}

normalize_kubernetes_version() {
  local version="$1"
  version="${version#"${version%%[![:space:]]*}"}"
  version="${version%"${version##*[![:space:]]}"}"
  version="${version#v}"
  printf '%s\n' "${version}"
}

wait_for_kubernetes_version_convergence() {
  local constants_file="${1:-${cluster_constants_path}}"
  local timeout_seconds="${2:-1800}"
  local desired_version
  local desired_normalized
  local node_rows
  local current_normalized
  local start
  local all_ready
  local all_current
  local seen_mismatch=false

  desired_version="$(talos_kubernetes_version "${constants_file}")"
  desired_normalized="$(normalize_kubernetes_version "${desired_version}")"
  if [[ -z "${desired_normalized}" ]]; then
    return 0
  fi

  start="$(date +%s)"
  while true; do
    node_rows="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.nodeInfo.kubeletVersion}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
    all_ready=true
    all_current=true

    if [[ -z "${node_rows}" ]]; then
      all_ready=false
      all_current=false
    fi

    while IFS='|' read -r node_name node_version node_ready; do
      if [[ -z "${node_name}" ]]; then
        continue
      fi
      current_normalized="$(normalize_kubernetes_version "${node_version}")"
      if [[ "${current_normalized}" != "${desired_normalized}" ]]; then
        all_current=false
      fi
      if [[ "${node_ready}" != "True" ]]; then
        all_ready=false
      fi
    done <<< "${node_rows}"

    if [[ "${all_ready}" == "true" && "${all_current}" == "true" ]]; then
      if [[ "${seen_mismatch}" == "true" ]]; then
        message "Kubernetes nodes now report v${desired_normalized} and are Ready."
      fi
      return 0
    fi

    if [[ "${seen_mismatch}" != "true" ]]; then
      message "Waiting for Kubernetes nodes to converge to v${desired_normalized} and Ready state..."
      seen_mismatch=true
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Kubernetes nodes to converge to v${desired_normalized}. Current nodes:" >&2
      kubectl get nodes -o wide >&2 || true
      exit 1
    fi

    sleep 10
  done
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
trap report_current_section_failure ERR
message "Provider upgrades are disabled by default. Update manually when needed: tofu -chdir=<workspace> init -upgrade"
if [[ "${purge_external_ceph}" == "true" ]]; then
  if [[ "$(ceph_mode_from_constants "${cluster_ceph_constants_path}")" != "external" ]]; then
    error "--purge-external-ceph requires ceph_mode = \"external\" in ceph_constants.tf." >&2
    exit 1
  fi
fi

start_deploy_section "credentials"
run_ensure_credentials
finish_deploy_section "credentials"

configure_local_cluster_no_proxy

start_deploy_section "Talos/Kubernetes"
if [[ "${services_only}" == "true" ]]; then
  message "Services-only requested; skipping Talos VM/root OpenTofu apply."
  require_cluster_file "${cluster_talosconfig_path}" "generated talosconfig"
  require_cluster_file "${cluster_kubeconfig_path}" "generated kubeconfig"
else
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

    if [[ "${purge_credentials}" == "true" ]]; then
      purge_cluster_credentials
    fi

    message "Removing generated cluster runtime workspace at ${cluster_out_dir}..."
    purge_cluster_out_dir

    if [[ "${destroy_only}" == "true" ]]; then
      finish_deploy_section "Talos/Kubernetes" "destroyed"
      message "Destroy-only requested; exiting without deploying."
      exit 0
    fi

    run_ensure_credentials
  fi

  message "Deploying the Talos cluster ${cluster_name} (PVE VMs creation, Talos cluster initialization, k8s bootstrapping)..."
  run_gen_talos_assets
  run_tofu_init "${cluster_root_workspace}"
  mapfile -t root_apply_extra_args < <(root_apply_args)
  run tofu -chdir="${cluster_root_workspace}" apply -auto-approve "${root_apply_extra_args[@]}"

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
fi

export TALOSCONFIG="${cluster_talosconfig_path}"
active_kubeconfig_path="${cluster_kubeconfig_path}"
bootstrap_kubeconfig_path=""
if [[ "${services_only}" != "true" && -n "${controlplane_vip}" ]]; then
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
if [[ "${services_only}" == "true" ]]; then
  message "Services-only requested; skipping Talos disk, version, and kubelet settings preflight checks."
  finish_deploy_section "Talos/Kubernetes" "skipped"
else
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
  stage_secondary_network_worker_configs
  reconcile_secondary_network_workers
  wait_for_kubernetes_version_convergence "${cluster_constants_path}"
  reboot_nodes_with_pending_kubelet_max_pods "${cluster_constants_path}"
  message "k8s cluster is up and running. Current nodes:"
  "${script_dir}/render-k8s-nodes.sh" --kubeconfig "${active_kubeconfig_path}"
  finish_deploy_section "Talos/Kubernetes"
fi

start_deploy_section "k8s-net"
if [[ "${skip_k8s_net}" == "true" ]]; then
  message "Skipping k8s networking and ingress (k8s-net) steps."
  finish_deploy_section "k8s-net" "skipped"
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

  finish_deploy_section "k8s-net"
fi

start_deploy_section "Rook Ceph"
if [[ "${skip_ceph}" == "true" ]]; then
  message "Skipping Rook Ceph steps."
  finish_deploy_section "Rook Ceph" "skipped"
else
  prepare_rook_workspaces
  ceph_mode_value="$(ceph_mode_from_constants "${cluster_ceph_constants_path}")"
  ceph_phase="$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${ceph_phase}" == "Ready" || ("${ceph_mode_value}" == "external" && "${ceph_phase}" == "Connected") ]]; then
    message "Rook Ceph cluster already healthy (phase=${ceph_phase}); reconciling cluster spec without operator bootstrap..."
    run_tofu_init "${cluster_rook_02_workspace}"
    run tofu -chdir="${cluster_rook_02_workspace}" apply -auto-approve -parallelism=1
    wait_for_cephcluster_ready "rook-ceph" "rook-ceph" "${ceph_mode_value}" "180"
  else
    message "Deploying Rook Ceph operator..."
    clear_rook_operator_restart_annotation
    run_tofu_init "${cluster_rook_01_workspace}"
    run tofu -chdir="${cluster_rook_01_workspace}" apply -auto-approve
    wait_for_pods_ready "rook-ceph" "rook-ceph-operator" "180s"

    message "Deploying Rook Ceph cluster..."
    run_tofu_init "${cluster_rook_02_workspace}"
    # External Ceph convergence uses imperative SSH/CLI calls against the same
    # Proxmox/Ceph management host; keep them serialized to avoid transient SSH
    # disconnects while multiple CephFS/pool operations run in parallel.
    run tofu -chdir="${cluster_rook_02_workspace}" apply -auto-approve -parallelism=1
    wait_for_cephcluster_ready "rook-ceph" "rook-ceph" "${ceph_mode_value}" "900"
  fi

  message "Deploying Rook Ceph CSI storage classes..."
  run_tofu_init "${cluster_rook_04_workspace}"
  run tofu -chdir="${cluster_rook_04_workspace}" apply -auto-approve
  if [[ "${ceph_mode_value}" == "external" ]]; then
    message "Waiting for Rook Ceph CSI resources to appear before restart..."
    wait_for_resource_existence "rook-ceph" "deploy/csi-cephfsplugin-provisioner" 120
    wait_for_resource_existence "rook-ceph" "deploy/csi-rbdplugin-provisioner" 120
    wait_for_resource_existence "rook-ceph" "daemonset/csi-cephfsplugin" 120
    wait_for_resource_existence "rook-ceph" "daemonset/csi-rbdplugin" 120

    message "Checking current Rook Ceph CSI rollout state before restart..."
    if ! check_rollout_status "rook-ceph" "deploy/csi-cephfsplugin-provisioner" "120s"; then
      message "CSI CephFS provisioner was not yet stable before restart; proceeding with restart."
    fi
    if ! check_rollout_status "rook-ceph" "deploy/csi-rbdplugin-provisioner" "120s"; then
      message "CSI RBD provisioner was not yet stable before restart; proceeding with restart."
    fi
    if ! check_rollout_status "rook-ceph" "daemonset/csi-cephfsplugin" "120s"; then
      message "CSI CephFS daemonset was not yet stable before restart; proceeding with restart."
    fi
    if ! check_rollout_status "rook-ceph" "daemonset/csi-rbdplugin" "120s"; then
      message "CSI RBD daemonset was not yet stable before restart; proceeding with restart."
    fi

    message "Allowing a short stabilization window before restarting Rook Ceph CSI components..."
    sleep 15

    message "Restarting Rook Ceph CSI components to reload external Ceph configuration..."
    kubectl -n rook-ceph rollout restart deploy/csi-cephfsplugin-provisioner 1>/dev/null
    kubectl -n rook-ceph rollout restart deploy/csi-rbdplugin-provisioner 1>/dev/null
    kubectl -n rook-ceph rollout restart daemonset/csi-cephfsplugin 1>/dev/null
    kubectl -n rook-ceph rollout restart daemonset/csi-rbdplugin 1>/dev/null
    wait_for_rollout_ready "rook-ceph" "deploy/csi-cephfsplugin-provisioner" "300s"
    wait_for_rollout_ready "rook-ceph" "deploy/csi-rbdplugin-provisioner" "180s"
    wait_for_rollout_ready "rook-ceph" "daemonset/csi-cephfsplugin" "300s"
    wait_for_rollout_ready "rook-ceph" "daemonset/csi-rbdplugin" "300s"
    message "Clearing Rook Ceph CSI leader-election leases after restart..."
    kubectl -n rook-ceph delete lease \
      rook-ceph-cephfs-csi-ceph-com \
      rook-ceph-rbd-csi-ceph-com \
      external-attacher-leader-rook-ceph-cephfs-csi-ceph-com \
      external-attacher-leader-rook-ceph-rbd-csi-ceph-com \
      external-resizer-rook-ceph-cephfs-csi-ceph-com \
      external-resizer-rook-ceph-rbd-csi-ceph-com \
      external-snapshotter-leader-rook-ceph-cephfs-csi-ceph-com \
      external-snapshotter-leader-rook-ceph-rbd-csi-ceph-com \
      --ignore-not-found 1>/dev/null
  fi
  kubectl -n rook-ceph get storageclasses.storage.k8s.io
  finish_deploy_section "Rook Ceph"
fi

start_deploy_section "identity"
if [[ "${skip_identity}" == "true" ]]; then
  message "Skipping identity services."
  finish_deploy_section "identity" "skipped"
else
  prepare_identity_workspace
  prepare_identity_config_workspace
  message "Deploying identity services..."
  run_tofu_init "${cluster_identity_workspace}"
  message "Refreshing one-shot Keycloak jobs before apply..."
  kubectl -n identity delete job keycloak-bootstrap-admin keycloak-configure-realms --ignore-not-found >/dev/null 2>&1 || true
  run tofu -chdir="${cluster_identity_workspace}" apply -auto-approve
  message "Waiting for identity PVCs, workloads, and endpoints to become ready..."
  wait_for_pvcs_bound "identity" "600" "keycloak-postgres-data"
  wait_for_deployments_ready "identity" "900s" "keycloak-postgres" "keycloak"
  wait_for_service_endpoints "identity" "900" "keycloak-postgres" "keycloak"
  message "Configuring Keycloak realms via API..."
  run_tofu_init "${cluster_identity_config_workspace}"
  run tofu -chdir="${cluster_identity_config_workspace}" apply -auto-approve
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
  finish_deploy_section "identity"
fi

start_deploy_section "S3 storage"
if [[ "${skip_s3_storage}" == "true" ]]; then
  message "Skipping S3-compatible storage services."
  finish_deploy_section "S3 storage" "skipped"
else
  prepare_s3_storage_workspace
  message "Deploying S3-compatible storage services (Garage)..."
  run_tofu_init "${cluster_s3_storage_workspace}"
  run tofu -chdir="${cluster_s3_storage_workspace}" apply -auto-approve \
    -var="cluster_name=${cluster_name}"
  s3_namespace="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw s3_namespace)"
  garage_name="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_name)"
  garage_replicas="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_replicas)"
  garage_console_auth_enabled="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_console_auth_enabled 2>/dev/null || printf "false")"
  s3_pvcs=()
  for ((i = 0; i < garage_replicas; i++)); do
    s3_pvcs+=("data-${garage_name}-${i}")
  done
  message "Waiting for S3 PVCs, workloads, and endpoints to become ready..."
  wait_for_pvcs_bound "${s3_namespace}" "600" "${s3_pvcs[@]}"
  wait_for_rollout_ready "${s3_namespace}" "statefulset/${garage_name}" "900s"
  wait_for_deployments_ready "${s3_namespace}" "600s" "console"
  wait_for_service_endpoints "${s3_namespace}" "600" "api" "admin" "console"
  if [[ "${garage_console_auth_enabled}" == "true" ]]; then
    wait_for_deployments_ready "${s3_namespace}" "600s" "console-oauth2-proxy"
    wait_for_service_endpoints "${s3_namespace}" "600" "console-oauth2-proxy"
  fi
  garage_s3_endpoint_url="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_s3_endpoint_url)"
  garage_internal_s3_endpoint_url="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_internal_s3_endpoint_url)"
  garage_console_url="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_console_url)"
  garage_s3_region="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_s3_region)"
  garage_admin_token="$(tofu -chdir="${cluster_s3_storage_workspace}" output -raw garage_admin_token)"
  message "S3 endpoint URL: ${URL_FMT_START}${garage_s3_endpoint_url}${URL_FMT_END}"
  message "S3 internal endpoint URL: ${URL_FMT_START}${garage_internal_s3_endpoint_url}${URL_FMT_END}"
  message "S3 region: ${DATA_FMT_START}${garage_s3_region}${DATA_FMT_END}"
  message "S3 Console URL: ${URL_FMT_START}${garage_console_url}${URL_FMT_END}"
  message "Garage admin token: ${DATA_FMT_START}${garage_admin_token}${DATA_FMT_END}"
  finish_deploy_section "S3 storage"
fi

start_deploy_section "monitoring"
if [[ "${skip_monitoring}" == "true" ]]; then
  message "Skipping monitoring stack."
  finish_deploy_section "monitoring" "skipped"
else
  prepare_monitoring_workspace
  message "Deploying monitoring stack..."
  run_tofu_init "${cluster_monitoring_workspace}"
  monitoring_prometheus_config_hash_before=""
  monitoring_tempo_config_rv_before=""
  monitoring_grafana_datasources_rv_before=""
  monitoring_grafana_dashboard_provider_rv_before=""
  if kubectl get namespace monitoring >/dev/null 2>&1; then
    monitoring_prometheus_config_hash_before="$(
      kubernetes_configmap_key_sha256 "monitoring" "prometheus-config" "prometheus.yml"
    )"
    monitoring_tempo_config_rv_before="$(
      kubernetes_resource_version "monitoring" "configmap" "tempo-config"
    )"
    monitoring_grafana_datasources_rv_before="$(
      kubernetes_resource_version "monitoring" "configmap" "grafana-datasources"
    )"
    monitoring_grafana_dashboard_provider_rv_before="$(
      kubernetes_resource_version "monitoring" "configmap" "grafana-dashboard-provider"
    )"
  fi
  run tofu -chdir="${cluster_monitoring_workspace}" apply -auto-approve
  monitoring_prometheus_config_hash_after="$(
    kubernetes_configmap_key_sha256 "monitoring" "prometheus-config" "prometheus.yml"
  )"
  monitoring_tempo_config_rv_after="$(
    kubernetes_resource_version "monitoring" "configmap" "tempo-config"
  )"
  monitoring_grafana_datasources_rv_after="$(
    kubernetes_resource_version "monitoring" "configmap" "grafana-datasources"
  )"
  monitoring_grafana_dashboard_provider_rv_after="$(
    kubernetes_resource_version "monitoring" "configmap" "grafana-dashboard-provider"
  )"
  monitoring_prometheus_config_changed=false
  monitoring_tempo_restart_needed=false
  monitoring_grafana_restart_needed=false
  if kubernetes_resource_changed "${monitoring_prometheus_config_hash_before}" "${monitoring_prometheus_config_hash_after}"; then
    monitoring_prometheus_config_changed=true
  fi
  if kubernetes_resource_changed "${monitoring_tempo_config_rv_before}" "${monitoring_tempo_config_rv_after}"; then
    monitoring_tempo_restart_needed=true
  fi
  if kubernetes_resource_changed "${monitoring_grafana_datasources_rv_before}" "${monitoring_grafana_datasources_rv_after}" \
    || kubernetes_resource_changed "${monitoring_grafana_dashboard_provider_rv_before}" "${monitoring_grafana_dashboard_provider_rv_after}"; then
    monitoring_grafana_restart_needed=true
  fi
  if [[ "${monitoring_grafana_restart_needed}" == "true" ]]; then
    message "Restarting Grafana to reload datasource or dashboard provisioning configuration..."
    kubectl -n monitoring rollout restart deploy/grafana 1>/dev/null
  fi
  if [[ "${monitoring_tempo_restart_needed}" == "true" ]]; then
    message "Restarting Tempo to reload tracing metrics configuration..."
    kubectl -n monitoring rollout restart deploy/tempo 1>/dev/null
  fi
  message "Waiting for monitoring PVCs, workloads, and endpoints to become ready..."
  monitoring_deployments=(grafana-postgres grafana loki tempo otel-collector prometheus kube-state-metrics)
  monitoring_daemonsets=(node-exporter promtail)
  monitoring_services=(grafana-postgres grafana loki tempo otel-collector prometheus kube-state-metrics node-exporter)
  monitoring_pvcs=(grafana-postgres-data grafana-data loki-data tempo-data prometheus-data)
  if kubectl -n monitoring get deploy/prometheus-oauth2-proxy >/dev/null 2>&1; then
    monitoring_deployments+=(prometheus-oauth2-proxy)
    monitoring_services+=(prometheus-oauth2-proxy)
  fi
  if kubectl -n monitoring get pvc dashboards-provisioning >/dev/null 2>&1; then
    monitoring_pvcs+=(dashboards-provisioning)
  fi
  wait_for_pvcs_bound "monitoring" "600" "${monitoring_pvcs[@]}"
  wait_for_deployments_ready "monitoring" "600s" "${monitoring_deployments[@]}"
  wait_for_daemonsets_ready "monitoring" "600s" "${monitoring_daemonsets[@]}"
  wait_for_service_endpoints "monitoring" "600" "${monitoring_services[@]}"
  grafana_dashboard_sync_job="$(
    kubectl -n monitoring get jobs -l app=grafana-dashboard-sync \
      -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | sort \
      | tail -n 1 \
      | awk '{ print $2 }'
  )"
  if [[ -n "${grafana_dashboard_sync_job}" ]]; then
    wait_for_job_complete "monitoring" "${grafana_dashboard_sync_job}" "600"
  fi
  if [[ "${monitoring_prometheus_config_changed}" == "true" ]]; then
    message "Reloading Prometheus scrape configuration..."
    wait_for_prometheus_config_hash "${monitoring_prometheus_config_hash_after}" "120"
    reload_prometheus_config
  fi
  grafana_url="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_url)"
  prometheus_url="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw prometheus_url)"
  prometheus_api_url="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw prometheus_api_url)"
  prometheus_api_user="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw prometheus_api_basic_auth_user)"
  prometheus_api_password="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw prometheus_api_basic_auth_password)"
  grafana_user="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_admin_user)"
  grafana_password="$(tofu -chdir="${cluster_monitoring_workspace}" output -raw grafana_admin_password)"
  message "Grafana URL: ${URL_FMT_START}${grafana_url}${URL_FMT_END}"
  message "Prometheus URL: ${URL_FMT_START}${prometheus_url}${URL_FMT_END}"
  message "Prometheus API URL: ${URL_FMT_START}${prometheus_api_url}${URL_FMT_END}"
  message "Prometheus API user: ${DATA_FMT_START}${prometheus_api_user}${DATA_FMT_END}"
  message "Prometheus API password: ${DATA_FMT_START}${prometheus_api_password}${DATA_FMT_END}"
  message "Grafana admin user: ${DATA_FMT_START}${grafana_user}${DATA_FMT_END}"
  message "Grafana admin password: ${DATA_FMT_START}${grafana_password}${DATA_FMT_END}"
  finish_deploy_section "monitoring"
fi

start_deploy_section "platform"
if [[ "${skip_platform}" == "true" ]]; then
  message "Skipping platform services."
  finish_deploy_section "platform" "skipped"
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
  message "Portainer bootstrap admin password: ${DATA_FMT_START}${portainer_admin_password}${DATA_FMT_END}"
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
  finish_deploy_section "platform"
fi

start_deploy_section "Kafka/Redpanda"
if [[ "${skip_kafka}" == "true" ]]; then
  message "Skipping Kafka/Redpanda services."
  finish_deploy_section "Kafka/Redpanda" "skipped"
else
  prepare_kafka_workspace
  message "Deploying Kafka/Redpanda services..."
  run_tofu_init "${cluster_kafka_workspace}"
  run tofu -chdir="${cluster_kafka_workspace}" apply -auto-approve
  kafka_namespace="$(tofu -chdir="${cluster_kafka_workspace}" output -raw redpanda_namespace)"
  redpanda_resource_name="$(tofu -chdir="${cluster_kafka_workspace}" output -raw redpanda_resource_name)"
  redpanda_broker_count="$(tofu -chdir="${cluster_kafka_workspace}" output -raw redpanda_broker_count)"
  redpanda_console_auth_enabled="$(tofu -chdir="${cluster_kafka_workspace}" output -raw redpanda_console_auth_enabled 2>/dev/null || printf "false")"
  kafka_pvcs=()
  for ((i = 0; i < redpanda_broker_count; i++)); do
    kafka_pvcs+=("datadir-${redpanda_resource_name}-${i}")
  done
  message "Waiting for Kafka/Redpanda PVCs, workloads, and endpoints to become ready..."
  wait_for_pvcs_bound "${kafka_namespace}" "600" "${kafka_pvcs[@]}"
  wait_for_rollout_ready "${kafka_namespace}" "statefulset/${redpanda_resource_name}" "900s"
  wait_for_deployments_ready "${kafka_namespace}" "600s" "${redpanda_resource_name}-console"
  wait_for_service_endpoints "${kafka_namespace}" "600" "${redpanda_resource_name}" "${redpanda_resource_name}-console"
  if [[ "${redpanda_console_auth_enabled}" == "true" ]]; then
    wait_for_deployments_ready "${kafka_namespace}" "600s" "${redpanda_resource_name}-console-oauth2-proxy"
    wait_for_service_endpoints "${kafka_namespace}" "600" "${redpanda_resource_name}-console-oauth2-proxy"
  fi
  redpanda_console_url="$(tofu -chdir="${cluster_kafka_workspace}" output -raw redpanda_console_url)"
  message "Redpanda Console URL: ${URL_FMT_START}${redpanda_console_url}${URL_FMT_END}"
  finish_deploy_section "Kafka/Redpanda"
fi

start_deploy_section "benchmark"
if [[ "${skip_benchmark}" == "true" ]]; then
  message "Skipping benchmark workloads."
  finish_deploy_section "benchmark" "skipped"
else
  prepare_benchmark_workspace
  message "Deploying benchmark workloads at zero replicas..."
  run_tofu_init "${cluster_benchmark_workspace}"
  run tofu -chdir="${cluster_benchmark_workspace}" apply -auto-approve
  benchmark_namespace="$(tofu -chdir="${cluster_benchmark_workspace}" output -raw benchmark_namespace)"
  benchmark_cpu_workload="$(tofu -chdir="${cluster_benchmark_workspace}" output -raw benchmark_cpu_workload)"
  benchmark_memory_workload="$(tofu -chdir="${cluster_benchmark_workspace}" output -raw benchmark_memory_workload)"
  benchmark_disk_workloads="$(tofu -chdir="${cluster_benchmark_workspace}" output -raw benchmark_disk_workload_summary)"
  message "Benchmark namespace: ${DATA_FMT_START}${benchmark_namespace}${DATA_FMT_END}"
  message "CPU benchmark: kubectl -n ${benchmark_namespace} scale deployment/${benchmark_cpu_workload} --replicas=<n>"
  message "Memory benchmark: kubectl -n ${benchmark_namespace} scale deployment/${benchmark_memory_workload} --replicas=<n>"
  if [[ -n "${benchmark_disk_workloads}" ]]; then
    message "Disk benchmarks: ${DATA_FMT_START}${benchmark_disk_workloads}${DATA_FMT_END}"
  fi
  finish_deploy_section "benchmark"
fi

start_deploy_section "Rook Ceph dashboard"
ceph_mode_value="$(ceph_mode_from_constants "${cluster_ceph_constants_path}")"
if [[ "${skip_ceph}" == "true" || "${skip_k8s_net}" == "true" || "${ceph_mode_value}" == "external" ]]; then
  if [[ "${ceph_mode_value}" == "external" && "${skip_ceph}" != "true" ]]; then
    message "Skipping Rook Ceph dashboard ingress for external Ceph mode."
  fi
  finish_deploy_section "Rook Ceph dashboard" "skipped"
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
  finish_deploy_section "Rook Ceph dashboard"
fi

start_deploy_section "credentials and URLs report"
write_credentials_and_urls_report
finish_deploy_section "credentials and URLs report"

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
