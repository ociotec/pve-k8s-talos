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
EOF
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
  local payload
  payload="$(cat)"
  JSON_INPUT="${payload}" python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
payload = json.loads(os.environ["JSON_INPUT"])

value = payload
for part in expr.split("."):
    if part == "":
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is None:
    sys.exit(1)

if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

pool_exists() {
  local node="$1"
  local pool_name="$2"
  local payload

  payload="$(api_get "/nodes/${node}/ceph/pool")"
  JSON_INPUT="${payload}" python3 - "${pool_name}" <<'PY'
import json
import os
import sys

pool_name = sys.argv[1]
payload = json.loads(os.environ["JSON_INPUT"])
for item in payload.get("data", []):
    name = item.get("pool_name") or item.get("pool") or item.get("name")
    if name == pool_name:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

discover_ceph_node() {
  local payload
  payload="$(api_get "/nodes")"
  JSON_INPUT="${payload}" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_INPUT"])
for item in payload.get("data", []):
    if item.get("status") == "online":
        name = item.get("node")
        if name:
            print(name)
            raise SystemExit(0)
raise SystemExit(1)
PY
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

set_pool_autoscale_on() {
  local node="$1"
  local pool_name="$2"
  local response upid

  response="$(
    api_put "/nodes/${node}/ceph/pool/${pool_name}" \
      --data-urlencode "pg_autoscale_mode=on"
  )"
  upid="$(printf '%s' "${response}" | json_extract "data")"
  wait_for_task "${node}" "${upid}"
  echo "Pool ${pool_name} autoscale mode set to on."
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
    echo "Pool ${pool_name} already exists on ${node}, skipping."
    set_pool_autoscale_on "${node}" "${pool_name}"
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
  set_pool_autoscale_on "${node}" "${pool_name}"
}

main() {
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
