#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pve-ceph-external.sh ensure-rbd-pool [options]

Options:
  --node <name>            Optional Proxmox node that owns the local Ceph management API.
  --name <pool-name>       Base pool name.
  --type <replicated|ec>   Pool type.
  --pg-num <n>             Initial PG count.
  --size <n>               Replicated pool size, or metadata pool size for EC.
  --min-size <n>           Replicated pool min_size, or metadata pool min_size for EC.
  --k <n>                  EC data chunks.
  --m <n>                  EC coding chunks.

Environment:
  PROXMOX_VE_ENDPOINT      Example: https://pve.example.com:8006/
  PROXMOX_VE_API_TOKEN     Example: root@pam!token=secret
  PROXMOX_VE_INSECURE      Set to true/1 to skip TLS verification
  CEPH_SSH_USER            SSH user for Ceph CLI fallback. Default: root
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

curl_common_args() {
  local args=(
    --silent
    --show-error
    --fail
    --header "Authorization: PVEAPIToken ${PROXMOX_VE_API_TOKEN}"
  )

  if [[ "${PROXMOX_VE_INSECURE:-}" == "true" || "${PROXMOX_VE_INSECURE:-}" == "1" ]]; then
    args+=(--insecure)
  fi

  printf '%s\n' "${args[@]}"
}

api_get() {
  local path="$1"
  local endpoint="${PROXMOX_VE_ENDPOINT%/}/api2/json${path}"
  mapfile -t args < <(curl_common_args)
  curl "${args[@]}" "${endpoint}"
}

api_post() {
  local path="$1"
  shift
  local endpoint="${PROXMOX_VE_ENDPOINT%/}/api2/json${path}"
  mapfile -t args < <(curl_common_args)
  curl "${args[@]}" --request POST "$@" "${endpoint}"
}

api_put() {
  local path="$1"
  shift
  local endpoint="${PROXMOX_VE_ENDPOINT%/}/api2/json${path}"
  mapfile -t args < <(curl_common_args)
  curl "${args[@]}" --request PUT "$@" "${endpoint}"
}

json_extract() {
  local expr="$1"
  jq -er ".${expr}"
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

pool_exists() {
  local node="$1"
  local pool_name="$2"
  local payload

  payload="$(api_get "/nodes/${node}/ceph/pool")"
  printf '%s' "${payload}" \
    | jq -er --arg pool_name "${pool_name}" '.data[] | (.pool_name // .pool // .name) | select(. == $pool_name)' >/dev/null
}

discover_ceph_node() {
  local payload
  payload="$(api_get "/nodes")"
  printf '%s' "${payload}" | jq -er '.data[] | select(.status == "online") | .node' | head -n 1
}

wait_for_task() {
  local node="$1"
  local upid="$2"
  local started_at
  started_at="$(date +%s)"

  while true; do
    local payload status exitstatus
    payload="$(api_get "/nodes/${node}/tasks/${upid}/status")"
    status="$(printf '%s' "${payload}" | json_extract "data.status" || true)"
    exitstatus="$(printf '%s' "${payload}" | json_extract "data.exitstatus" || true)"

    if [[ "${status}" == "stopped" ]]; then
      if [[ "${exitstatus}" == "OK" ]]; then
        return 0
      fi
      echo "PVE task ${upid} failed with exit status: ${exitstatus:-unknown}" >&2
      exit 1
    fi

    if (( $(date +%s) - started_at > 600 )); then
      echo "Timed out waiting for PVE task ${upid}" >&2
      exit 1
    fi

    sleep 3
  done
}

wait_for_pool_exists() {
  local node="$1"
  local pool_name="$2"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if pool_exists "${node}" "${pool_name}"; then
      return 0
    fi

    if (( $(date +%s) - started_at > 120 )); then
      echo "Timed out waiting for Ceph pool ${pool_name} to appear on ${node}" >&2
      exit 1
    fi

    sleep 3
  done
}

set_pool_autoscale_on() {
  local node="$1"
  local pool_name="$2"
  set_pool_properties "${node}" "${pool_name}" \
    "autoscale mode set to on" \
    --data-urlencode "pg_autoscale_mode=on"
}

set_pool_size_settings() {
  local node="$1"
  local pool_name="$2"
  local size="$3"
  local min_size="$4"

  set_pool_properties "${node}" "${pool_name}" \
    "size set to ${size}, min_size set to ${min_size}" \
    --data-urlencode "size=${size}" \
    --data-urlencode "min_size=${min_size}"
}

set_pool_properties() {
  local node="$1"
  local pool_name="$2"
  local description="$3"
  shift 3
  local started_at last_error
  started_at="$(date +%s)"

  while true; do
    if try_set_pool_properties "${node}" "${pool_name}" "$@"; then
      echo "Pool ${pool_name} ${description}."
      return 0
    fi

    last_error="${pool_update_error}"
    if (( $(date +%s) - started_at > 120 )); then
      echo "Timed out updating Ceph pool ${pool_name}: ${last_error}" >&2
      exit 1
    fi

    sleep 3
  done
}

try_set_pool_properties() {
  local node="$1"
  local pool_name="$2"
  shift 2
  local response upid

  pool_update_error=""
  if ! response="$(api_put "/nodes/${node}/ceph/pool/${pool_name}" "$@" 2>&1)"; then
    pool_update_error="${response}"
    return 1
  fi

  if ! upid="$(printf '%s' "${response}" | json_extract "data" 2>/dev/null)"; then
    pool_update_error="Unexpected Proxmox API response while updating pool ${pool_name}: ${response}"
    return 1
  fi

  wait_for_task "${node}" "${upid}"
}

set_pool_allow_ec_overwrites() {
  local node="$1"
  local pool_name="$2"

  if try_set_pool_properties "${node}" "${pool_name}" --data-urlencode "allow_ec_overwrites=1"; then
    echo "Pool ${pool_name} allow_ec_overwrites set to on."
    return 0
  fi

  echo "Proxmox Ceph API rejected allow_ec_overwrites for pool ${pool_name}; falling back to Ceph CLI over SSH." >&2
  set_pool_allow_ec_overwrites_via_ssh "${node}" "${pool_name}"
}

set_pool_allow_ec_overwrites_via_ssh() {
  local node="$1"
  local pool_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local quoted_pool

  require_cmd ssh
  quoted_pool="$(shell_quote "${pool_name}")"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${node}" \
    "ceph osd pool set ${quoted_pool} allow_ec_overwrites true" 1>/dev/null
  echo "Pool ${pool_name} allow_ec_overwrites set to on via Ceph CLI."
}

converge_rbd_pool() {
  local node="$1"
  local pool_name="$2"
  local pool_type="$3"
  local size="$4"
  local min_size="$5"

  set_pool_size_settings "${node}" "${pool_name}" "${size}" "${min_size}"
  set_pool_autoscale_on "${node}" "${pool_name}"

  if [[ "${pool_type}" == "ec" ]]; then
    set_pool_allow_ec_overwrites "${node}" "${pool_name}"
  fi
}

ensure_rbd_pool() {
  local node=""
  local pool_name=""
  local pool_type=""
  local pg_num=""
  local size=""
  local min_size=""
  local k=""
  local m=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node)
        node="$2"
        shift 2
        ;;
      --name)
        pool_name="$2"
        shift 2
        ;;
      --type)
        pool_type="$2"
        shift 2
        ;;
      --pg-num)
        pg_num="$2"
        shift 2
        ;;
      --size)
        size="$2"
        shift 2
        ;;
      --min-size)
        min_size="$2"
        shift 2
        ;;
      --k)
        k="$2"
        shift 2
        ;;
      --m)
        m="$2"
        shift 2
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

  require_env PROXMOX_VE_ENDPOINT
  require_env PROXMOX_VE_API_TOKEN

  if [[ -z "${pool_name}" || -z "${pool_type}" || -z "${pg_num}" || -z "${size}" || -z "${min_size}" ]]; then
    echo "Missing required ensure-rbd-pool arguments." >&2
    usage >&2
    exit 1
  fi

  if [[ -z "${node}" ]]; then
    node="$(discover_ceph_node || true)"
    if [[ -z "${node}" ]]; then
      echo "Unable to auto-discover a Proxmox node for Ceph API operations." >&2
      exit 1
    fi
  fi

  if [[ "${pool_type}" != "replicated" && "${pool_type}" != "ec" ]]; then
    echo "--type must be replicated or ec" >&2
    exit 1
  fi

  if pool_exists "${node}" "${pool_name}"; then
    echo "Pool ${pool_name} already exists on ${node}, converging settings."
    converge_rbd_pool "${node}" "${pool_name}" "${pool_type}" "${size}" "${min_size}"
    return 0
  fi

  local response upid

  if [[ "${pool_type}" == "replicated" ]]; then
    response="$(
      api_post "/nodes/${node}/ceph/pool" \
        --data-urlencode "name=${pool_name}" \
        --data-urlencode "pg_num=${pg_num}" \
        --data-urlencode "size=${size}" \
        --data-urlencode "min_size=${min_size}" \
        --data-urlencode "add_storages=0"
    )"
  else
    if [[ -z "${k}" || -z "${m}" ]]; then
      echo "EC pools require --k and --m." >&2
      exit 1
    fi

    response="$(
      api_post "/nodes/${node}/ceph/pool" \
        --data-urlencode "name=${pool_name}" \
        --data-urlencode "pg_num=${pg_num}" \
        --data-urlencode "size=${size}" \
        --data-urlencode "min_size=${min_size}" \
        --data-urlencode "erasure-coding=k=${k},m=${m}" \
        --data-urlencode "add_storages=0"
    )"
  fi

  upid="$(printf '%s' "${response}" | json_extract "data")"
  wait_for_task "${node}" "${upid}"
  echo "Pool ${pool_name} created on ${node}."

  # Replicated pools show up consistently in the Proxmox Ceph pool list right
  # away. EC pools can lag there, so their convergence uses the retrying pool
  # update endpoint directly instead of depending on the list endpoint.
  if [[ "${pool_type}" == "replicated" ]]; then
    wait_for_pool_exists "${node}" "${pool_name}"
  fi
  converge_rbd_pool "${node}" "${pool_name}" "${pool_type}" "${size}" "${min_size}"
}

main() {
  require_cmd curl
  require_cmd jq

  if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
  fi

  local command="$1"
  shift

  case "${command}" in
    ensure-rbd-pool)
      ensure_rbd_pool "$@"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
