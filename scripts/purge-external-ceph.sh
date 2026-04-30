#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  purge-external-ceph.sh --cluster-name <name> --ceph-constants <path>

Options:
  --cluster-name <name>     Cluster name used for log messages.
  --ceph-constants <path>   Path to ceph_constants.tf.

Environment:
  CEPH_SSH_USER             SSH user for the Ceph monitor host. Default: root
EOF
}

require_local_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    error "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

hcl_string_value() {
  local file="$1"
  local key="$2"
  local default_value="$3"
  local value

  value="$(awk -v key="${key}" -F'"' '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print $2
      exit
    }
  ' "${file}")"
  printf '%s\n' "${value:-${default_value}}"
}

hcl_block_body() {
  local file="$1"
  local block="$2"

  awk -v block="${block}" '
    $0 ~ "^[[:space:]]*" block "[[:space:]]*=[[:space:]]*\\{" {
      in_block = 1
      next
    }
    in_block && $0 ~ "^[[:space:]]*}" {
      exit
    }
    in_block {
      print
    }
  ' "${file}"
}

hcl_block_string_value() {
  local block_body="$1"
  local key="$2"
  local default_value="$3"
  local value

  value="$(printf '%s\n' "${block_body}" | awk -v key="${key}" -F'"' '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print $2
      exit
    }
  ')"
  printf '%s\n' "${value:-${default_value}}"
}

hcl_block_bool_value() {
  local block_body="$1"
  local key="$2"
  local default_value="$3"
  local value

  value="$(printf '%s\n' "${block_body}" | awk -v key="${key}" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$" {
      gsub(/.*=[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ')"
  printf '%s\n' "${value:-${default_value}}"
}

first_monitor_host() {
  local file="$1"
  local value

  value="$(
    awk -F'"' '
      /id[[:space:]]*=/ {
        print $2
        exit
      }
    ' "${file}"
  )"

  if [[ -z "${value}" ]]; then
    return 1
  fi

  value="${value#mon.}"
  printf '%s\n' "${value}"
}

remote_ceph() {
  local remote_cmd="$1"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ceph_ssh_user}@${ceph_monitor_host}" "${remote_cmd}"
}

ceph_pool_exists() {
  local pool_name="$1"
  local output

  if ! output="$(remote_ceph "ceph osd pool ls --format json")"; then
    error "Failed to query Ceph pools while checking ${pool_name} on ${ceph_monitor_host}." >&2
    exit 1
  fi

  printf '%s' "${output}" | jq -er --arg pool "${pool_name}" '.[] | select(. == $pool)' >/dev/null 2>&1
}

ceph_filesystem_exists() {
  local filesystem_name="$1"
  local output

  if ! output="$(remote_ceph "ceph fs volume ls --format json")"; then
    error "Failed to query Ceph filesystems while checking ${filesystem_name} on ${ceph_monitor_host}." >&2
    exit 1
  fi

  printf '%s' "${output}" | jq -er --arg fs "${filesystem_name}" '.[] | select(.name == $fs)' >/dev/null 2>&1
}

purge_rbd_pool_images() {
  local pool_name="$1"
  local output
  local image_name

  if ! ceph_pool_exists "${pool_name}"; then
    message "External Ceph pool ${pool_name} is already absent."
    return 0
  fi

  output="$(remote_ceph "rbd ls ${pool_name} --format json")"
  if [[ "${output}" == "[]" ]]; then
    return 0
  fi

  message "Deleting orphaned RBD images from pool ${pool_name}..."
  while IFS= read -r image_name; do
    [[ -z "${image_name}" ]] && continue
    remove_rbd_image_with_retries "${pool_name}" "${image_name}"
  done < <(printf '%s' "${output}" | jq -r '.[]')

  remote_ceph "rbd trash purge ${pool_name} --threshold 0" 1>/dev/null 2>&1 || true
}

remove_rbd_image_with_retries() {
  local pool_name="$1"
  local image_name="$2"
  local attempt
  local max_attempts=12
  local sleep_seconds=10
  local status_output=""

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if remote_ceph "rbd rm ${pool_name}/${image_name}" 1>/dev/null 2>/dev/null; then
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep "${sleep_seconds}"
    fi
  done

  status_output="$(remote_ceph "rbd status ${pool_name}/${image_name}" 2>/dev/null || true)"
  error "Failed to delete RBD image ${pool_name}/${image_name} after waiting $((max_attempts * sleep_seconds))s." >&2
  if [[ -n "${status_output}" ]]; then
    printf '%s\n' "${status_output}" >&2
  fi
  exit 1
}

delete_pool_if_present() {
  local pool_name="$1"

  if [[ -z "${pool_name}" ]]; then
    return 0
  fi

  if ! ceph_pool_exists "${pool_name}"; then
    message "External Ceph pool ${pool_name} is already absent."
    return 0
  fi

  message "Deleting external Ceph pool ${pool_name}..."
  remote_ceph "ceph osd pool rm ${pool_name} ${pool_name} --yes-i-really-really-mean-it" 1>/dev/null
}

delete_cephfs_if_present() {
  local filesystem_name="$1"

  if ! ceph_filesystem_exists "${filesystem_name}"; then
    message "External Ceph filesystem ${filesystem_name} is already absent."
    return 0
  fi

  message "Deleting external Ceph filesystem ${filesystem_name}..."
  remote_ceph "ceph fs volume rm ${filesystem_name} --yes-i-really-mean-it" 1>/dev/null
}

cluster_name=""
ceph_constants_path=""
ceph_ssh_user="${CEPH_SSH_USER:-root}"
ceph_monitor_host=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      cluster_name="$2"
      shift 2
      ;;
    --ceph-constants)
      ceph_constants_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${cluster_name}" || -z "${ceph_constants_path}" ]]; then
  usage >&2
  exit 1
fi

require_local_cmd jq
require_local_cmd ssh

if [[ ! -r "${ceph_constants_path}" ]]; then
  error "Cannot read ceph constants file: ${ceph_constants_path}" >&2
  exit 1
fi

ceph_mode="$(hcl_string_value "${ceph_constants_path}" "ceph_mode" "internal")"
if [[ "${ceph_mode}" != "external" ]]; then
  error "--purge-external-ceph requires ceph_mode = \"external\" in ceph_constants.tf." >&2
  exit 1
fi

ceph_monitor_host="$(first_monitor_host "${ceph_constants_path}" || true)"
if [[ -z "${ceph_monitor_host}" ]]; then
  error "Unable to derive a Ceph monitor host from ceph_constants.tf." >&2
  exit 1
fi

ceph_prefix="$(hcl_string_value "${ceph_constants_path}" "ceph_name_prefix" "cluster")"

block_replicated_body="$(hcl_block_body "${ceph_constants_path}" "ceph_block_replicated")"
block_ec_body="$(hcl_block_body "${ceph_constants_path}" "ceph_block_ec")"
filesystem_replicated_body="$(hcl_block_body "${ceph_constants_path}" "ceph_filesystem_replicated")"
filesystem_ec_body="$(hcl_block_body "${ceph_constants_path}" "ceph_filesystem_ec")"

block_replicated_enabled="$(hcl_block_bool_value "${block_replicated_body}" "enabled" "false")"
block_ec_enabled="$(hcl_block_bool_value "${block_ec_body}" "enabled" "false")"
filesystem_replicated_enabled="$(hcl_block_bool_value "${filesystem_replicated_body}" "enabled" "false")"
filesystem_ec_enabled="$(hcl_block_bool_value "${filesystem_ec_body}" "enabled" "false")"

declare -a summaries=()
declare -a cephfs_specs=()
declare -a rbd_pool_specs=()

if [[ "${block_replicated_enabled}" == "true" ]]; then
  block_replicated_pool_name="$(hcl_block_string_value "${block_replicated_body}" "pool_name" "${ceph_prefix}-rbd-replica")"
  summaries+=("RBD pool: ${block_replicated_pool_name}")
  rbd_pool_specs+=("${block_replicated_pool_name}|true")
fi

if [[ "${block_ec_enabled}" == "true" ]]; then
  block_ec_pool_name="$(hcl_block_string_value "${block_ec_body}" "pool_name" "${ceph_prefix}-rbd-ec")"
  block_ec_metadata_pool_name="$(hcl_block_string_value "${block_ec_body}" "metadata_pool_name" "${ceph_prefix}-rbd-ec-metadata")"
  block_ec_data_pool_name="$(hcl_block_string_value "${block_ec_body}" "data_pool_name" "${ceph_prefix}-rbd-ec-data")"
  summaries+=("RBD pool: ${block_ec_metadata_pool_name}")
  summaries+=("RBD pool: ${block_ec_data_pool_name}")
  rbd_pool_specs+=("${block_ec_metadata_pool_name}|true")
  rbd_pool_specs+=("${block_ec_data_pool_name}|false")
  if [[ "${block_ec_pool_name}" != "${block_ec_data_pool_name}" ]]; then
    rbd_pool_specs+=("${block_ec_data_pool_name}-metadata|true")
    rbd_pool_specs+=("${block_ec_data_pool_name}-data|false")
  fi
fi

if [[ "${filesystem_replicated_enabled}" == "true" ]]; then
  fs_rep_name="$(hcl_block_string_value "${filesystem_replicated_body}" "filesystem_name" "${ceph_prefix}-cephfs-replica")"
  fs_rep_metadata_pool_name="$(hcl_block_string_value "${filesystem_replicated_body}" "metadata_pool_name" "${ceph_prefix}-cephfs-replica-metadata")"
  fs_rep_data_pool_name="$(hcl_block_string_value "${filesystem_replicated_body}" "data_pool_name" "${ceph_prefix}-cephfs-replica-data")"
  summaries+=("CephFS: ${fs_rep_name}")
  cephfs_specs+=("${fs_rep_name}|${fs_rep_metadata_pool_name}|${fs_rep_data_pool_name}|")
fi

if [[ "${filesystem_ec_enabled}" == "true" ]]; then
  fs_ec_name="$(hcl_block_string_value "${filesystem_ec_body}" "filesystem_name" "${ceph_prefix}-cephfs-ec")"
  fs_ec_metadata_pool_name="$(hcl_block_string_value "${filesystem_ec_body}" "metadata_pool_name" "${ceph_prefix}-cephfs-ec-metadata")"
  fs_ec_default_data_pool_name="$(hcl_block_string_value "${filesystem_ec_body}" "default_data_pool_name" "${ceph_prefix}-cephfs-ec-default")"
  fs_ec_data_pool_name="$(hcl_block_string_value "${filesystem_ec_body}" "ec_data_pool_name" "${ceph_prefix}-cephfs-ec-data")"
  summaries+=("CephFS: ${fs_ec_name}")
  cephfs_specs+=("${fs_ec_name}|${fs_ec_metadata_pool_name}|${fs_ec_default_data_pool_name}|${fs_ec_data_pool_name}")
fi

message "External Ceph purge requested for cluster ${cluster_name} on ${ceph_ssh_user}@${ceph_monitor_host}:"
for summary in "${summaries[@]}"; do
  message "  - ${summary}"
done

for spec in "${cephfs_specs[@]}"; do
  IFS='|' read -r filesystem_name metadata_pool_name data_pool_name extra_pool_name <<< "${spec}"
  delete_cephfs_if_present "${filesystem_name}"
  delete_pool_if_present "${extra_pool_name}"
  delete_pool_if_present "${data_pool_name}"
  delete_pool_if_present "${metadata_pool_name}"
done

for spec in "${rbd_pool_specs[@]}"; do
  IFS='|' read -r pool_name check_rbd_images <<< "${spec}"
  if [[ "${check_rbd_images}" == "true" ]]; then
    purge_rbd_pool_images "${pool_name}"
  fi
  delete_pool_if_present "${pool_name}"
done

message "External Ceph purge completed."
