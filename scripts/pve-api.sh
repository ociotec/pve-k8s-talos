#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pve-api.sh <command> [options]

Commands:
  config-vm    Configure a VM via the Proxmox API.
  set-hotplug  Configure VM hotplug settings.
  start-vm     Start a VM.

Options (all commands):
  --node <name>    Proxmox node name.
  --vmid <id>      VM ID.
  -h, --help       Show this help message.

Options (config-vm only):
  --data <query>   Query string passed to the API (e.g. "hotplug=cpu,mem").

Options (set-hotplug only):
  --hotplug <val>   Hotplug value (e.g. "cpu,memory,disk,network,usb").
  --enable-numa     Also enable NUMA (required for memory hotplug).

Environment:
  PROXMOX_VE_ENDPOINT  Proxmox API endpoint (https://host:8006).
  PROXMOX_VE_API_TOKEN API token (preferred).
  PROXMOX_VE_USERNAME  Username for password auth.
  PROXMOX_VE_PASSWORD  Password for password auth.
  PROXMOX_VE_INSECURE  Set to 1/true/yes to skip TLS verification.
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

endpoint_from_env() {
  local endpoint
  endpoint="${PROXMOX_VE_ENDPOINT:-}"
  [[ -n "${endpoint}" ]] || die "PROXMOX_VE_ENDPOINT must be set."
  endpoint="${endpoint%/}"
  if [[ "${endpoint}" != http://* && "${endpoint}" != https://* ]]; then
    endpoint="https://${endpoint}"
  fi
  printf '%s' "${endpoint}"
}

curl_args_from_env() {
  local -a args
  case "${PROXMOX_VE_INSECURE:-}" in
    1|true|yes|y|TRUE|YES|Y) args+=(-k) ;;
  esac
  printf '%s\0' "${args[@]}"
}

require_auth() {
  if [[ -n "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -n "${PROXMOX_VE_USERNAME:-}" && -n "${PROXMOX_VE_PASSWORD:-}" ]]; then
    command -v jq >/dev/null 2>&1 || die "jq is required for Proxmox password auth."
    return 0
  fi
  die "Set PROXMOX_VE_API_TOKEN or PROXMOX_VE_USERNAME/PROXMOX_VE_PASSWORD."
}

request_with_token() {
  local method="$1"
  local url="$2"
  shift 2
  curl "$@" -sS -w '\n%{http_code}' -X "${method}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}" \
    "${url}"
}

request_with_ticket() {
  local method="$1"
  local url="$2"
  shift 2
  local ticket_resp ticket_code ticket_body ticket csrf

  ticket_resp="$(curl "$@" -sS -w '\n%{http_code}' -X POST \
    "$(endpoint_from_env)/api2/json/access/ticket" \
    -d "username=${PROXMOX_VE_USERNAME}&password=${PROXMOX_VE_PASSWORD}")"
  ticket_code="$(printf '%s\n' "${ticket_resp}" | tail -n 1)"
  ticket_body="$(printf '%s\n' "${ticket_resp}" | sed '$d')"
  [[ "${ticket_code}" =~ ^2 ]] || die "Ticket request failed (${ticket_code}): ${ticket_body}"
  ticket="$(printf '%s' "${ticket_body}" | jq -r .data.ticket)"
  csrf="$(printf '%s' "${ticket_body}" | jq -r .data.CSRFPreventionToken)"
  [[ -n "${ticket}" && "${ticket}" != "null" && -n "${csrf}" && "${csrf}" != "null" ]] \
    || die "Ticket response missing auth data: ${ticket_body}"

  curl "$@" -sS -w '\n%{http_code}' -X "${method}" \
    -H "CSRFPreventionToken: ${csrf}" \
    -H "Cookie: PVEAuthCookie=${ticket}" \
    "${url}"
}

pve_request() {
  local method="$1"
  local path="$2"
  shift 2
  local endpoint url resp code body
  local -a curl_args

  require_auth
  endpoint="$(endpoint_from_env)"
  url="${endpoint}/api2/json${path}"

  while IFS= read -r -d '' arg; do
    curl_args+=("${arg}")
  done < <(curl_args_from_env)

  if [[ -n "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    resp="$(request_with_token "${method}" "${url}" "${curl_args[@]}" "$@")"
  else
    resp="$(request_with_ticket "${method}" "${url}" "${curl_args[@]}" "$@")"
  fi

  code="$(printf '%s\n' "${resp}" | tail -n 1)"
  body="$(printf '%s\n' "${resp}" | sed '$d')"
  [[ "${code}" =~ ^2 ]] || die "API request failed (${code}): ${body}"
  printf '%s' "${body}"
}

config_vm() {
  local node="$1"
  local vmid="$2"
  local data="$3"
  [[ -n "${node}" ]] || die "Missing --node."
  [[ -n "${vmid}" ]] || die "Missing --vmid."
  [[ -n "${data}" ]] || die "Missing --data."
  pve_request POST "/nodes/${node}/qemu/${vmid}/config" -d "${data}" >/dev/null
}

set_hotplug() {
  local node="$1"
  local vmid="$2"
  local hotplug="$3"
  local enable_numa="$4"
  local data
  [[ -n "${hotplug}" ]] || die "Missing --hotplug."
  data="hotplug=${hotplug}"
  if [[ "${enable_numa}" == "true" ]]; then
    data="${data}&numa=1"
  fi
  config_vm "${node}" "${vmid}" "${data}"
}

start_vm() {
  local node="$1"
  local vmid="$2"
  [[ -n "${node}" ]] || die "Missing --node."
  [[ -n "${vmid}" ]] || die "Missing --vmid."
  pve_request POST "/nodes/${node}/qemu/${vmid}/status/start" >/dev/null
}

cmd="${1:-}"
shift || true

node=""
vmid=""
data=""
hotplug=""
enable_numa="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      node="$2"
      shift 2
      ;;
    --vmid)
      vmid="$2"
      shift 2
      ;;
    --data)
      data="$2"
      shift 2
      ;;
    --hotplug)
      hotplug="$2"
      shift 2
      ;;
    --enable-numa)
      enable_numa="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

case "${cmd}" in
  config-vm)
    config_vm "${node}" "${vmid}" "${data}"
    ;;
  set-hotplug)
    set_hotplug "${node}" "${vmid}" "${hotplug}" "${enable_numa}"
    ;;
  start-vm)
    start_vm "${node}" "${vmid}"
    ;;
  ""|-h|--help)
    usage
    ;;
  *)
    die "Unknown command: ${cmd}"
    ;;
esac
