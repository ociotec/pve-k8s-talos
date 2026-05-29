#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

export TF_VAR_proxmox_endpoint="${TF_VAR_proxmox_endpoint:-${PROXMOX_VE_ENDPOINT:-}}"
export TF_VAR_proxmox_api_token="${TF_VAR_proxmox_api_token:-${PROXMOX_VE_API_TOKEN:-}}"
export TF_VAR_proxmox_insecure="${TF_VAR_proxmox_insecure:-${PROXMOX_VE_INSECURE:-}}"

usage() {
  cat <<'USAGE'
Usage: deploy-infra-vm.sh [options]

Deploys one bootstrap/infra VM from infra-vms/<name>.

Options:
  -d, --destroy       Destroy the infra VM first, then apply it again.
  -D, --destroy-only  Destroy the infra VM and exit.
      --plan          Prepare, init, validate, and show an OpenTofu plan only.
      --prepare-only  Prepare the generated workspace and exit.
  -v, --verbose       Show all OpenTofu output.
  -g, --debug         Enable shell tracing + verbose output (sets TF_LOG=DEBUG).
  -h, --help          Show this help message.

Run from infra-vms/<name>, preferably with:
  direnv exec . ../../scripts/deploy-infra-vm.sh
USAGE
}

destroy_first=false
destroy_only=false
plan_only=false
prepare_only=false
verbose=false
debug=false
temporary_ssh_agent_started=false
script_start="$(start_timer)"

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
    --plan)
      plan_only=true
      shift
      ;;
    --prepare-only)
      prepare_only=true
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

repo_root="$(cd "${script_dir}/.." && pwd -P)"
infra_vms_dir="${repo_root}/infra-vms"
current_dir="$(pwd -P)"
current_parent="$(basename "$(dirname "${current_dir}")")"
infra_vm_name="$(basename "${current_dir}")"

if [[ "${current_parent}" != "infra-vms" ]]; then
  error "Run this script from infra-vms/<name>."
  exit 1
fi

if [[ "${infra_vm_name}" == "sample" ]]; then
  error "infra-vms/sample is only for examples; copy it to a real infra-vm directory first."
  exit 1
fi

if [[ "${current_dir}" != "${infra_vms_dir}/${infra_vm_name}" ]]; then
  error "Expected to run from ${infra_vms_dir}/${infra_vm_name}, but current directory is ${current_dir}."
  exit 1
fi

if [[ "${destroy_only}" == "true" && "${plan_only}" == "true" ]]; then
  error "--destroy-only cannot be combined with --plan."
  exit 1
fi

if [[ "${prepare_only}" == "true" && ( "${destroy_first}" == "true" || "${plan_only}" == "true" ) ]]; then
  error "--prepare-only cannot be combined with destroy or plan options."
  exit 1
fi

if [[ "${debug}" == "true" ]]; then
  set -x
  export TF_LOG=DEBUG
fi

cleanup_temporary_ssh_agent() {
  if [[ "${temporary_ssh_agent_started}" == "true" ]]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}
trap cleanup_temporary_ssh_agent EXIT

infra_vm_out_dir="${current_dir}/out"
infra_vm_workspace="${infra_vm_out_dir}/root"
infra_vm_known_hosts="${infra_vm_workspace}/ssh_known_hosts"
constants_path="${current_dir}/constants.auto.tfvars"
services_path="${current_dir}/services.auto.tfvars"
infra_vm_username=""
infra_vm_hostname=""
infra_vm_domain=""
infra_vm_ip=""
infra_vm_reboot_after_provisioning=""
docker_enabled=""
discovery_enabled=""
discovery_server_name=""
discovery_public_port=""
trusted_ca_path=""

require_cluster_file "${constants_path}" "infra-vm constants"
require_cluster_file "${services_path}" "infra-vm services constants"

tf_string_value() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" -F'"' '$0 ~ "^[[:space:]]*\"" name "\"[[:space:]]*=" { print $4; exit }' "${file}" 2>/dev/null || true
}

load_infra_vm_connection_info() {
  infra_vm_username="$(tf_string_value "${constants_path}" username)"
  infra_vm_hostname="$(tf_string_value "${constants_path}" hostname)"
  infra_vm_ip="$(tf_string_value "${constants_path}" ip)"
  infra_vm_reboot_after_provisioning="$(awk -F= '/"reboot_after_provisioning"[[:space:]]*=/ { gsub(/[[:space:],]/, "", $2); print $2; exit }' "${constants_path}" 2>/dev/null || true)"
  trusted_ca_path="$(tf_string_value "${constants_path}" trusted_ca_paths)"
  docker_enabled="$(awk -F= '/"enabled"[[:space:]]*=/ && in_docker { gsub(/[[:space:],]/, "", $2); print $2; exit } /"docker"[[:space:]]*=[[:space:]]*{/ { in_docker=1 } in_docker && /^[[:space:]]*}/ { in_docker=0 }' "${services_path}" 2>/dev/null || true)"
  discovery_enabled="$(awk -F= '/"enabled"[[:space:]]*=/ && in_discovery { gsub(/[[:space:],]/, "", $2); print $2; exit } /"talos_discovery"[[:space:]]*=[[:space:]]*{/ { in_discovery=1 } in_discovery && /^[[:space:]]*}/ { in_discovery=0 }' "${services_path}" 2>/dev/null || true)"
  discovery_server_name="$(tf_string_value "${services_path}" server_name)"
  discovery_public_port="$(awk -F= '/"public_port"[[:space:]]*=/ { gsub(/[[:space:],]/, "", $2); print $2; exit }' "${services_path}" 2>/dev/null || true)"

  if [[ -z "${infra_vm_hostname}" ]]; then
    infra_vm_hostname="$(tf_string_value "${constants_path}" name)"
  fi
  if [[ -z "${infra_vm_reboot_after_provisioning}" ]]; then
    infra_vm_reboot_after_provisioning="true"
  fi
  if [[ -z "${docker_enabled}" ]]; then
    docker_enabled="true"
  fi
  if [[ -z "${discovery_enabled}" ]]; then
    discovery_enabled="true"
  fi
  if [[ -z "${discovery_public_port}" ]]; then
    discovery_public_port="443"
  fi
}

message_ssh_connection_info() {
  if [[ -z "${infra_vm_username}" || -z "${infra_vm_hostname}" || -z "${infra_vm_ip}" ]]; then
    return 0
  fi
  message "Connect via SSH with: ssh ${infra_vm_username}@${infra_vm_hostname} (${infra_vm_ip})"
}

run() {
  if [[ "${verbose}" == "true" ]]; then
    "$@"
  else
    "$@" 1>/dev/null
  fi
}

ssh_agent_has_keys() {
  SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" ssh-add -L >/dev/null 2>&1
}

ensure_proxmox_ssh_agent() {
  local key_file

  if [[ "${PROXMOX_VE_SSH_AGENT:-}" != "true" ]]; then
    return 0
  fi

  if ssh_agent_has_keys; then
    return 0
  fi

  key_file="${INFRA_VM_PROXMOX_SSH_KEY_FILE:-}"
  if [[ -z "${key_file}" && -r "${HOME}/.ssh/id_ed25519" ]]; then
    key_file="${HOME}/.ssh/id_ed25519"
  fi
  if [[ -z "${key_file}" && -r "${HOME}/.ssh/id_rsa" ]]; then
    key_file="${HOME}/.ssh/id_rsa"
  fi

  if [[ -z "${key_file}" ]]; then
    error "PROXMOX_VE_SSH_AGENT=true but no SSH key is loaded and no key file was found." >&2
    error "Run ssh-add before deploying, or set INFRA_VM_PROXMOX_SSH_KEY_FILE in .envrc." >&2
    exit 1
  fi

  key_file="$(eval printf '%s' "${key_file}")"
  if [[ ! -r "${key_file}" ]]; then
    error "Configured INFRA_VM_PROXMOX_SSH_KEY_FILE is not readable: ${key_file}" >&2
    exit 1
  fi

  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null
    temporary_ssh_agent_started=true
  fi

  message "Loading Proxmox SSH key into ssh-agent for snippet upload..."
  ssh-add "${key_file}" >/dev/null

  if ! ssh_agent_has_keys; then
    error "ssh-agent has no loaded keys after ssh-add." >&2
    exit 1
  fi
}

ssh_infra_vm() {
  ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${infra_vm_known_hosts}" \
    -o ConnectTimeout=8 \
    "${infra_vm_username}@${infra_vm_ip}" \
    "$@"
}

reset_infra_vm_known_host() {
  if [[ -z "${infra_vm_ip}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${infra_vm_known_hosts}")"
  ssh-keygen -f "${infra_vm_known_hosts}" -R "${infra_vm_ip}" >/dev/null 2>&1 || true
}

remove_known_host_entry() {
  local known_hosts_file="$1"
  local host="$2"

  if [[ -z "${host}" || ! -f "${known_hosts_file}" ]]; then
    return 0
  fi

  ssh-keygen -f "${known_hosts_file}" -R "${host}" >/dev/null 2>&1 || true
}

cleanup_destroyed_vm_known_hosts() {
  local user_known_hosts="${HOME}/.ssh/known_hosts"
  local hosts=(
    "${infra_vm_ip}"
    "${infra_vm_hostname}"
    "${discovery_server_name}"
  )
  local host

  message "Removing local SSH known_hosts entries for destroyed infra VM..."
  for host in "${hosts[@]}"; do
    remove_known_host_entry "${infra_vm_known_hosts}" "${host}"
    remove_known_host_entry "${user_known_hosts}" "${host}"
  done
}

wait_for_infra_vm_ssh() {
  local timeout_seconds="${1:-600}"
  local start

  start="$(date +%s)"
  while true; do
    if ssh_infra_vm true >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for SSH on ${infra_vm_ip}." >&2
      return 1
    fi
    sleep 5
  done
}

wait_for_infra_vm_reboot_if_needed() {
  local before_boot_id="$1"
  local timeout_seconds="${2:-600}"
  local start
  local current_boot_id

  if [[ "${infra_vm_reboot_after_provisioning}" != "true" || -z "${before_boot_id}" ]]; then
    return 0
  fi

  start="$(date +%s)"
  while true; do
    current_boot_id="$(ssh_infra_vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    if [[ -n "${current_boot_id}" && "${current_boot_id}" != "${before_boot_id}" ]]; then
      return 0
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for mandatory infra VM reboot after provisioning." >&2
      return 1
    fi
    sleep 5
  done
}

verify_infra_vm_ready() {
  local verify_start
  local before_boot_id
  local service_names=(qemu-guest-agent)
  local ca_arg=()
  local discovery_url

  verify_start="$(start_timer)"
  reset_infra_vm_known_host
  message "Waiting for infra VM SSH on ${infra_vm_ip}..."
  wait_for_infra_vm_ssh 600
  before_boot_id="$(ssh_infra_vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"

  message "Waiting for cloud-init to finish on ${infra_vm_ip}..."
  ssh_infra_vm 'sudo cloud-init status --wait'

  wait_for_infra_vm_reboot_if_needed "${before_boot_id}" 600
  wait_for_infra_vm_ssh 300

  message "Checking infra VM services..."
  if [[ "${docker_enabled}" == "true" ]]; then
    service_names+=(docker)
  fi
  if [[ "${discovery_enabled}" == "true" ]]; then
    service_names+=(nginx talos-discovery)
  fi
  ssh_infra_vm "systemctl is-active ${service_names[*]}"

  if [[ "${discovery_enabled}" == "true" && -n "${discovery_server_name}" ]]; then
    discovery_url="https://${discovery_server_name}:${discovery_public_port}/"
    message "Checking discovery HTTPS endpoint ${discovery_url} via ${infra_vm_ip}..."
    if [[ -n "${trusted_ca_path}" ]]; then
      ca_arg=(--cacert "${current_dir}/${trusted_ca_path#./}")
    else
      ca_arg=(-k)
    fi
    curl --noproxy '*' \
      --resolve "${discovery_server_name}:${discovery_public_port}:${infra_vm_ip}" \
      "${ca_arg[@]}" \
      --max-time 15 \
      --silent \
      --show-error \
      --output /dev/null \
      "${discovery_url}"
  fi

  message "Infra VM ${infra_vm_name} is ready in $(render_elapsed "${verify_start}")."
}

clear_stale_lock_if_present() {
  local workspace="$1"
  local lock_path="${workspace}/.terraform.tfstate.lock.info"

  if [[ ! -f "${lock_path}" ]]; then
    return 0
  fi

  if pgrep -af "tofu -chdir=${workspace}" >/dev/null 2>&1; then
    error "OpenTofu workspace appears to be locked by a running process: ${workspace}" >&2
    exit 1
  fi

  message "Removing stale OpenTofu lock in ${workspace}..."
  rm -f "${lock_path}"
}

prepare_workspace() {
  mkdir -p "${infra_vm_workspace}" "${current_dir}/certs" "${current_dir}/secrets"
  if [[ -d "${repo_root}/.terraform" ]]; then
    link_into_workspace "${repo_root}/.terraform" "${infra_vm_workspace}/.terraform"
  fi
  link_into_workspace "${repo_root}/infra-vm/main.tf" "${infra_vm_workspace}/main.tf"
  link_into_workspace "${repo_root}/infra-vm/providers.tf" "${infra_vm_workspace}/providers.tf"
  link_into_workspace "${repo_root}/infra-vm/cloud-init.yaml.tftpl" "${infra_vm_workspace}/cloud-init.yaml.tftpl"
  link_into_workspace "${constants_path}" "${infra_vm_workspace}/constants.auto.tfvars"
  link_into_workspace "${services_path}" "${infra_vm_workspace}/services.auto.tfvars"
  link_into_workspace "${current_dir}/certs" "${infra_vm_workspace}/certs"
  link_into_workspace "${current_dir}/secrets" "${infra_vm_workspace}/secrets"
  if [[ -r "${repo_root}/.terraform.lock.hcl" ]]; then
    link_into_workspace "${repo_root}/.terraform.lock.hcl" "${infra_vm_workspace}/.terraform.lock.hcl"
  fi
}

tofu_init() {
  clear_stale_lock_if_present "${infra_vm_workspace}"
  message "Initializing OpenTofu providers in ${infra_vm_workspace}..."
  run tofu -chdir="${infra_vm_workspace}" init
}

tofu_validate() {
  message "Validating infra-vm workspace..."
  run tofu -chdir="${infra_vm_workspace}" validate
}

prepare_workspace
load_infra_vm_connection_info

if [[ "${prepare_only}" == "true" ]]; then
  message "Prepared ${infra_vm_workspace} in $(render_elapsed "${script_start}")."
  message_ssh_connection_info
  exit 0
fi

tofu_init
tofu_validate

ensure_proxmox_ssh_agent

if [[ "${destroy_first}" == "true" ]]; then
  message "Destroying infra VM ${infra_vm_name}..."
  # Avoid provider refresh hangs on broken mid-boot VMs; destroy from the local state.
  run tofu -chdir="${infra_vm_workspace}" destroy -refresh=false -auto-approve
  cleanup_destroyed_vm_known_hosts
  if [[ "${destroy_only}" == "true" ]]; then
    message "Infra VM ${infra_vm_name} destroyed in $(render_elapsed "${script_start}")."
    message_ssh_connection_info
    exit 0
  fi
fi

if [[ "${plan_only}" == "true" ]]; then
  message "Planning infra VM ${infra_vm_name}..."
  tofu -chdir="${infra_vm_workspace}" plan
  message "Infra VM ${infra_vm_name} plan finished in $(render_elapsed "${script_start}")."
  message_ssh_connection_info
  exit 0
fi

message "Applying infra VM ${infra_vm_name}..."
run tofu -chdir="${infra_vm_workspace}" apply -auto-approve
verify_infra_vm_ready
message "Infra VM ${infra_vm_name} deployment finished in $(render_elapsed "${script_start}")."
message_ssh_connection_info
