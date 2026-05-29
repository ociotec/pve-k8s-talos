#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pve-ceph-external.sh ensure-rbd-pool [options]
  pve-ceph-external.sh ensure-cephfs [options]

Options:
  --node <name>            Optional Proxmox node that owns the local Ceph management API.
  --ssh-host <host>        Optional host/IP for Ceph CLI SSH operations. Defaults to --node.
  --name <pool-name>       Base pool name.
  --type <replicated|ec>   Pool type.
  --pg-num <n>             Initial PG count.
  --size <n>               Replicated pool size, or metadata pool size for EC.
  --min-size <n>           Replicated pool min_size, or metadata pool min_size for EC.
  --k <n>                  EC data chunks.
  --m <n>                  EC coding chunks.

CephFS options:
  --name <fs-name>                 CephFS filesystem name.
  --type <replicated|ec>           CephFS data pool shape.
  --metadata-pool <pool-name>      Replicated metadata pool.
  --metadata-pg-num <n>            Metadata pool initial PG count.
  --metadata-size <n>              Metadata pool replicated size.
  --metadata-min-size <n>          Metadata pool min_size.
  --data-pool <pool-name>          Replicated data pool, or default data pool for EC CephFS.
  --data-pg-num <n>                Data/default data pool initial PG count.
  --data-size <n>                  Data/default data pool replicated size.
  --data-min-size <n>              Data/default data pool min_size.
  --ec-data-pool <pool-name>       Additional EC data pool for --type ec.
  --ec-data-pg-num <n>             EC data pool initial PG count.
  --ec-data-size <n>               EC data pool EC size.
  --ec-data-min-size <n>           EC data pool min_size.

Environment:
  PROXMOX_VE_ENDPOINT      Example: https://pve.example.com:8006/
  PROXMOX_VE_API_TOKEN     Example: root@pam!token=secret
  PROXMOX_VE_INSECURE      Set to true/1 to skip TLS verification
  CEPH_SSH_USER            SSH user for Ceph CLI fallback. Default: root
  CEPH_SSH_HOST            SSH host/IP for ensure-cephfs.
  CEPH_CLI_TIMEOUT         Timeout in seconds for Ceph CLI SSH commands. Default: 60
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

ceph_cli_timeout() {
  local timeout_seconds="${CEPH_CLI_TIMEOUT:-60}"
  if [[ ! "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
    echo "CEPH_CLI_TIMEOUT must be a positive integer, got: ${timeout_seconds}" >&2
    exit 1
  fi
  printf '%s' "${timeout_seconds}"
}

remote_ceph_cmd() {
  local ceph_args="$1"
  printf 'timeout %s ceph %s' "$(ceph_cli_timeout)" "${ceph_args}"
}

pool_exists() {
  local node="$1"
  local pool_name="$2"
  local payload

  payload="$(api_get "/nodes/${node}/ceph/pool")"
  printf '%s' "${payload}" \
    | jq -er --arg pool_name "${pool_name}" '.data[] | (.pool_name // .pool // .name) | select(. == $pool_name)' >/dev/null
}

ceph_pool_exists_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "osd pool ls --format json")")"
  printf '%s' "${payload}" | jq -er --arg pool_name "${pool_name}" '.[] | select(. == $pool_name)' >/dev/null
}

ceph_filesystem_exists_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "fs ls --format json")")"
  printf '%s' "${payload}" | jq -er --arg filesystem_name "${filesystem_name}" '.[] | select(.name == $filesystem_name)' >/dev/null
}

ceph_filesystem_has_data_pool_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local pool_name="$3"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "fs ls --format json")")"
  printf '%s' "${payload}" | jq -er \
    --arg filesystem_name "${filesystem_name}" \
    --arg pool_name "${pool_name}" \
    '.[] | select(.name == $filesystem_name) | .data_pools[]? | select(. == $pool_name)' >/dev/null
}

ceph_subvolume_group_exists_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local group_name="$3"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  if ! payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "fs subvolumegroup ls $(shell_quote "${filesystem_name}") --format json")" 2>&1)"; then
    echo "Failed to list CephFS ${filesystem_name} subvolume groups on ${ssh_host}: ${payload}" >&2
    return 2
  fi
  printf '%s' "${payload}" | jq -er --arg group_name "${group_name}" '.[] | select(.name == $group_name)' >/dev/null
}

ceph_filesystem_has_active_mds_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "fs dump --format json")")"
  printf '%s' "${payload}" | jq -er \
    --arg filesystem_name "${filesystem_name}" \
    '.filesystems[] | select(.mdsmap.fs_name == $filesystem_name) | (.mdsmap.up | length > 0)' >/dev/null
}

ceph_mds_daemon_exists_via_ssh() {
  local ssh_host="$1"
  local mds_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local payload

  payload="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "fs dump --format json")")"
  printf '%s' "${payload}" | jq -er \
    --arg mds_name "${mds_name}" \
    '([.standbys[]?.name] + [.filesystems[]?.mdsmap.info[]?.name])[] | select(. == $mds_name)' >/dev/null
}

ensure_ec_profile_via_ssh() {
  local ssh_host="$1"
  local profile_name="$2"
  local k="$3"
  local m="$4"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local quoted_profile output

  quoted_profile="$(shell_quote "${profile_name}")"
  if output="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "osd erasure-code-profile get ${quoted_profile}")" 2>&1)"; then
    if ! grep -qx "k=${k}" <<<"${output}" || ! grep -qx "m=${m}" <<<"${output}" || ! grep -qx "crush-failure-domain=host" <<<"${output}"; then
      echo "Erasure-code profile ${profile_name} already exists on ${ssh_host}, but it does not match k=${k}, m=${m}, crush-failure-domain=host." >&2
      echo "Refusing to overwrite an existing Ceph erasure-code profile." >&2
      exit 1
    fi

    echo "Erasure-code profile ${profile_name} already exists on ${ssh_host} with the expected settings."
    return 0
  fi

  if ! grep -Eq "ENOENT|not found|does not exist|doesn't exist" <<<"${output}"; then
    printf '%s\n' "${output}" >&2
    exit 1
  fi

  run_ceph_via_ssh "${ssh_host}" "osd erasure-code-profile set ${quoted_profile} k=${k} m=${m} crush-failure-domain=host --force"
  echo "Erasure-code profile ${profile_name} created on ${ssh_host}."
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
  task_wait_error=""

  while true; do
    local payload status exitstatus
    payload="$(api_get "/nodes/${node}/tasks/${upid}/status")"
    status="$(printf '%s' "${payload}" | json_extract "data.status" || true)"
    exitstatus="$(printf '%s' "${payload}" | json_extract "data.exitstatus" || true)"

    if [[ "${status}" == "stopped" ]]; then
      if [[ "${exitstatus}" == "OK" ]]; then
        return 0
      fi
      task_wait_error="PVE task ${upid} failed with exit status: ${exitstatus:-unknown}"
      return 1
    fi

    if (( $(date +%s) - started_at > 600 )); then
      task_wait_error="Timed out waiting for PVE task ${upid}"
      return 1
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

  if ! wait_for_task "${node}" "${upid}"; then
    pool_update_error="${task_wait_error:-PVE task ${upid} failed}"
    return 1
  fi
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
  local ssh_host="$1"
  local pool_name="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local quoted_pool

  require_cmd ssh
  quoted_pool="$(shell_quote "${pool_name}")"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "osd pool set ${quoted_pool} allow_ec_overwrites true")" 1>/dev/null
  echo "Pool ${pool_name} allow_ec_overwrites set to on via Ceph CLI."
}

run_ceph_via_ssh() {
  local ssh_host="$1"
  local ceph_args="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"

  require_cmd ssh
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "$(remote_ceph_cmd "${ceph_args}")" 1>/dev/null
}

run_remote_via_ssh() {
  local ssh_host="$1"
  local remote_cmd="$2"
  local ssh_user="${CEPH_SSH_USER:-root}"

  require_cmd ssh
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "${remote_cmd}" 1>/dev/null
}

ensure_cephfs_active_mds_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local mds_name="$3"
  local quoted_mds_name
  local started_at

  if ceph_filesystem_has_active_mds_via_ssh "${ssh_host}" "${filesystem_name}"; then
    echo "CephFS ${filesystem_name} already has an active MDS."
    return 0
  fi

  if ceph_mds_daemon_exists_via_ssh "${ssh_host}" "${mds_name}"; then
    echo "MDS ${mds_name} already exists on ${ssh_host}; waiting for CephFS ${filesystem_name} to activate."
  else
    quoted_mds_name="$(shell_quote "${mds_name}")"
    run_remote_via_ssh "${ssh_host}" "pveceph mds create --name ${quoted_mds_name}"
    echo "MDS ${mds_name} created on ${ssh_host}."
  fi

  started_at="$(date +%s)"
  while true; do
    if ceph_filesystem_has_active_mds_via_ssh "${ssh_host}" "${filesystem_name}"; then
      echo "CephFS ${filesystem_name} has an active MDS."
      return 0
    fi

    if (( $(date +%s) - started_at > 180 )); then
      echo "Timed out waiting for CephFS ${filesystem_name} to get an active MDS." >&2
      exit 1
    fi

    sleep 3
  done
}

ensure_cephfs_csi_subvolume_group_via_ssh() {
  local ssh_host="$1"
  local filesystem_name="$2"
  local data_pool="$3"
  local ssh_user="${CEPH_SSH_USER:-root}"
  local group_name="csi"
  local quoted_filesystem quoted_group quoted_data_pool
  local exists_status
  local create_output

  if ceph_subvolume_group_exists_via_ssh "${ssh_host}" "${filesystem_name}" "${group_name}"; then
    echo "CephFS ${filesystem_name} subvolume group ${group_name} already exists."
    return 0
  fi
  exists_status=$?
  if [[ "${exists_status}" -ne 1 ]]; then
    echo "Could not verify CephFS ${filesystem_name} subvolume group ${group_name}; attempting idempotent create." >&2
  fi

  quoted_filesystem="$(shell_quote "${filesystem_name}")"
  quoted_group="$(shell_quote "${group_name}")"
  quoted_data_pool="$(shell_quote "${data_pool}")"
  if ! create_output="$(
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
      "$(remote_ceph_cmd "fs subvolumegroup create ${quoted_filesystem} ${quoted_group} 0 ${quoted_data_pool}")" 2>&1
  )"; then
    if printf '%s\n' "${create_output}" | grep -Eiq 'already exists|eexist|file exists'; then
      echo "CephFS ${filesystem_name} subvolume group ${group_name} already exists."
      return 0
    fi

    echo "Failed to create CephFS ${filesystem_name} subvolume group ${group_name}: ${create_output}" >&2
    exit 1
  fi

  echo "CephFS ${filesystem_name} subvolume group ${group_name} created with pool layout ${data_pool}."
}

converge_replicated_pool_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local size="$3"
  local min_size="$4"
  local quoted_pool

  quoted_pool="$(shell_quote "${pool_name}")"
  run_ceph_via_ssh "${ssh_host}" "osd pool set ${quoted_pool} size ${size}"
  run_ceph_via_ssh "${ssh_host}" "osd pool set ${quoted_pool} min_size ${min_size}"
  run_ceph_via_ssh "${ssh_host}" "osd pool set ${quoted_pool} pg_autoscale_mode on"
  echo "Replicated pool ${pool_name} converged via Ceph CLI."
}

ensure_replicated_pool_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local pg_num="$3"
  local size="$4"
  local min_size="$5"
  local quoted_pool

  require_cmd ssh
  quoted_pool="$(shell_quote "${pool_name}")"

  if ceph_pool_exists_via_ssh "${ssh_host}" "${pool_name}"; then
    echo "Pool ${pool_name} already exists on ${ssh_host}, converging settings via Ceph CLI."
    converge_replicated_pool_via_ssh "${ssh_host}" "${pool_name}" "${size}" "${min_size}"
    return 0
  fi

  run_ceph_via_ssh "${ssh_host}" "osd pool create ${quoted_pool} ${pg_num} ${pg_num} replicated"
  echo "Pool ${pool_name} created on ${ssh_host} via Ceph CLI."
  converge_replicated_pool_via_ssh "${ssh_host}" "${pool_name}" "${size}" "${min_size}"
}

converge_ec_pool_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local min_size="$3"
  local application="$4"
  local quoted_pool ssh_user output

  quoted_pool="$(shell_quote "${pool_name}")"
  ssh_user="${CEPH_SSH_USER:-root}"
  run_ceph_via_ssh "${ssh_host}" "osd pool application enable ${quoted_pool} ${application} --yes-i-really-mean-it"
  run_ceph_via_ssh "${ssh_host}" "osd pool set ${quoted_pool} min_size ${min_size}"
  run_ceph_via_ssh "${ssh_host}" "osd pool set ${quoted_pool} pg_autoscale_mode on"

  if ! output="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ssh_user}@${ssh_host}" \
    "ceph osd pool set ${quoted_pool} allow_ec_overwrites true" 2>&1)"; then
    if grep -q "ec overwrites can only be enabled for an erasure coded pool" <<<"${output}"; then
      echo "Pool ${pool_name} is not erasure-coded; skipping allow_ec_overwrites." >&2
    else
      printf '%s\n' "${output}" >&2
      exit 1
    fi
  fi

  echo "Pool ${pool_name} converged via Ceph CLI."
}

ensure_ec_rbd_pool_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local pg_num="$3"
  local min_size="$4"
  local k="$5"
  local m="$6"
  local profile_name="${pool_name}-profile"
  local quoted_pool quoted_profile

  require_cmd ssh
  quoted_pool="$(shell_quote "${pool_name}")"
  quoted_profile="$(shell_quote "${profile_name}")"

  if ceph_pool_exists_via_ssh "${ssh_host}" "${pool_name}"; then
    echo "Pool ${pool_name} already exists on ${ssh_host}, converging settings via Ceph CLI."
    converge_ec_pool_via_ssh "${ssh_host}" "${pool_name}" "${min_size}" "rbd"
    return 0
  fi

  ensure_ec_profile_via_ssh "${ssh_host}" "${profile_name}" "${k}" "${m}"
  run_ceph_via_ssh "${ssh_host}" "osd pool create ${quoted_pool} ${pg_num} ${pg_num} erasure ${quoted_profile}"
  echo "Pool ${pool_name} created on ${ssh_host} via Ceph CLI."
  converge_ec_pool_via_ssh "${ssh_host}" "${pool_name}" "${min_size}" "rbd"
}

ensure_ec_cephfs_pool_via_ssh() {
  local ssh_host="$1"
  local pool_name="$2"
  local pg_num="$3"
  local min_size="$4"
  local k="$5"
  local m="$6"
  local profile_name="${pool_name}-profile"
  local quoted_pool quoted_profile

  require_cmd ssh
  quoted_pool="$(shell_quote "${pool_name}")"
  quoted_profile="$(shell_quote "${profile_name}")"

  if ceph_pool_exists_via_ssh "${ssh_host}" "${pool_name}"; then
    echo "Pool ${pool_name} already exists on ${ssh_host}, converging settings via Ceph CLI."
    converge_ec_pool_via_ssh "${ssh_host}" "${pool_name}" "${min_size}" "cephfs"
    return 0
  fi

  ensure_ec_profile_via_ssh "${ssh_host}" "${profile_name}" "${k}" "${m}"
  run_ceph_via_ssh "${ssh_host}" "osd pool create ${quoted_pool} ${pg_num} ${pg_num} erasure ${quoted_profile}"
  echo "Pool ${pool_name} created on ${ssh_host} via Ceph CLI."
  converge_ec_pool_via_ssh "${ssh_host}" "${pool_name}" "${min_size}" "cephfs"
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
  local ssh_host=""
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
      --ssh-host)
        ssh_host="$2"
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

  if [[ "${pool_type}" == "ec" ]]; then
    if [[ -z "${k}" || -z "${m}" ]]; then
      echo "EC pools require --k and --m." >&2
      exit 1
    fi

    if [[ -z "${ssh_host}" ]]; then
      ssh_host="${node}"
    fi

    ensure_ec_rbd_pool_via_ssh "${ssh_host}" "${pool_name}" "${pg_num}" "${min_size}" "${k}" "${m}"
    return 0
  fi

  if pool_exists "${node}" "${pool_name}"; then
    echo "Pool ${pool_name} already exists on ${node}, converging settings."
    converge_rbd_pool "${node}" "${pool_name}" "${pool_type}" "${size}" "${min_size}"
    return 0
  fi

  local response upid

  response="$(
    api_post "/nodes/${node}/ceph/pool" \
      --data-urlencode "name=${pool_name}" \
      --data-urlencode "pg_num=${pg_num}" \
      --data-urlencode "size=${size}" \
      --data-urlencode "min_size=${min_size}" \
      --data-urlencode "add_storages=0"
  )"

  upid="$(printf '%s' "${response}" | json_extract "data")"
  if ! wait_for_task "${node}" "${upid}"; then
    echo "${task_wait_error:-PVE task ${upid} failed}" >&2
    exit 1
  fi
  echo "Pool ${pool_name} created on ${node}."

  # Replicated pools show up consistently in the Proxmox Ceph pool list right
  # away. EC pools can lag there, so their convergence uses the retrying pool
  # update endpoint directly instead of depending on the list endpoint.
  if [[ "${pool_type}" == "replicated" ]]; then
    wait_for_pool_exists "${node}" "${pool_name}"
  fi
  converge_rbd_pool "${node}" "${pool_name}" "${pool_type}" "${size}" "${min_size}"
}

ensure_cephfs() {
  local ssh_host="${CEPH_SSH_HOST:-}"
  local filesystem_name=""
  local filesystem_type=""
  local metadata_pool=""
  local metadata_pg_num=""
  local metadata_size=""
  local metadata_min_size=""
  local data_pool=""
  local data_pg_num=""
  local data_size=""
  local data_min_size=""
  local ec_data_pool=""
  local ec_data_pg_num=""
  local ec_data_size=""
  local ec_data_min_size=""
  local k=""
  local m=""
  local csi_data_pool=""
  local quoted_filesystem quoted_metadata_pool quoted_data_pool quoted_ec_data_pool
  local filesystem_existed=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-host)
        ssh_host="$2"
        shift 2
        ;;
      --name)
        filesystem_name="$2"
        shift 2
        ;;
      --type)
        filesystem_type="$2"
        shift 2
        ;;
      --metadata-pool)
        metadata_pool="$2"
        shift 2
        ;;
      --metadata-pg-num)
        metadata_pg_num="$2"
        shift 2
        ;;
      --metadata-size)
        metadata_size="$2"
        shift 2
        ;;
      --metadata-min-size)
        metadata_min_size="$2"
        shift 2
        ;;
      --data-pool)
        data_pool="$2"
        shift 2
        ;;
      --data-pg-num)
        data_pg_num="$2"
        shift 2
        ;;
      --data-size)
        data_size="$2"
        shift 2
        ;;
      --data-min-size)
        data_min_size="$2"
        shift 2
        ;;
      --ec-data-pool)
        ec_data_pool="$2"
        shift 2
        ;;
      --ec-data-pg-num)
        ec_data_pg_num="$2"
        shift 2
        ;;
      --ec-data-size)
        ec_data_size="$2"
        shift 2
        ;;
      --ec-data-min-size)
        ec_data_min_size="$2"
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

  if [[ -z "${ssh_host}" ]]; then
    echo "ensure-cephfs requires --ssh-host or CEPH_SSH_HOST." >&2
    usage >&2
    exit 1
  fi

  if [[ -z "${filesystem_name}" || -z "${filesystem_type}" || -z "${metadata_pool}" || -z "${metadata_pg_num}" || -z "${metadata_size}" || -z "${metadata_min_size}" || -z "${data_pool}" || -z "${data_pg_num}" || -z "${data_size}" || -z "${data_min_size}" ]]; then
    echo "Missing required ensure-cephfs arguments." >&2
    usage >&2
    exit 1
  fi

  if [[ "${filesystem_type}" != "replicated" && "${filesystem_type}" != "ec" ]]; then
    echo "--type must be replicated or ec" >&2
    exit 1
  fi

  if [[ "${filesystem_type}" == "ec" && ( -z "${ec_data_pool}" || -z "${ec_data_pg_num}" || -z "${ec_data_size}" || -z "${ec_data_min_size}" || -z "${k}" || -z "${m}" ) ]]; then
    echo "EC CephFS requires --ec-data-pool, --ec-data-pg-num, --ec-data-size, --ec-data-min-size, --k, and --m." >&2
    usage >&2
    exit 1
  fi

  require_cmd ssh

  ensure_replicated_pool_via_ssh "${ssh_host}" "${metadata_pool}" "${metadata_pg_num}" "${metadata_size}" "${metadata_min_size}"
  ensure_replicated_pool_via_ssh "${ssh_host}" "${data_pool}" "${data_pg_num}" "${data_size}" "${data_min_size}"

  quoted_filesystem="$(shell_quote "${filesystem_name}")"
  quoted_metadata_pool="$(shell_quote "${metadata_pool}")"
  quoted_data_pool="$(shell_quote "${data_pool}")"

  if ceph_filesystem_exists_via_ssh "${ssh_host}" "${filesystem_name}"; then
    echo "CephFS ${filesystem_name} already exists on ${ssh_host}."
    filesystem_existed=true
  else
    run_ceph_via_ssh "${ssh_host}" "fs new ${quoted_filesystem} ${quoted_metadata_pool} ${quoted_data_pool}"
    echo "CephFS ${filesystem_name} created on ${ssh_host}."
  fi

  if [[ "${filesystem_type}" == "ec" ]]; then
    ensure_ec_cephfs_pool_via_ssh "${ssh_host}" "${ec_data_pool}" "${ec_data_pg_num}" "${ec_data_min_size}" "${k}" "${m}"

    if ceph_filesystem_has_data_pool_via_ssh "${ssh_host}" "${filesystem_name}" "${ec_data_pool}"; then
      echo "CephFS ${filesystem_name} already includes data pool ${ec_data_pool}."
    else
      quoted_ec_data_pool="$(shell_quote "${ec_data_pool}")"
      run_ceph_via_ssh "${ssh_host}" "fs add_data_pool ${quoted_filesystem} ${quoted_ec_data_pool}"
      echo "CephFS ${filesystem_name} data pool ${ec_data_pool} added."
    fi

    csi_data_pool="${ec_data_pool}"
  else
    csi_data_pool="${data_pool}"
  fi

  ensure_cephfs_active_mds_via_ssh "${ssh_host}" "${filesystem_name}" "${filesystem_name}"

  ensure_cephfs_csi_subvolume_group_via_ssh "${ssh_host}" "${filesystem_name}" "${csi_data_pool}"
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
    ensure-cephfs)
      ensure_cephfs "$@"
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
