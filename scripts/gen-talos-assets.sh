#!/usr/bin/env bash
set -euo pipefail

skip_ceph=false
skip_k8s_net=false
skip_portainer=false
skip_monitoring=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ceph)
      skip_ceph=true
      shift
      ;;
    --skip-k8s-net)
      skip_k8s_net=true
      shift
      ;;
    --skip-portainer)
      skip_portainer=true
      shift
      ;;
    --skip-monitoring)
      skip_monitoring=true
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: gen-talos-assets.sh [options]

Options:
  --skip-ceph         Exclude Rook Ceph hostnames from generated no_proxy values.
  --skip-k8s-net      Exclude k8s-net ingress IP/hostnames from generated no_proxy values.
  --skip-portainer    Exclude Portainer hostname from generated no_proxy values.
  --skip-monitoring   Exclude monitoring hostnames from generated no_proxy values.
  -h, --help          Show this help message.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_path="${repo_root}/patches/machine.template.yaml"
hostname_template_path="${repo_root}/patches/hostname.template.yaml"
qemu_template_path="${repo_root}/patches/qemu.template.yaml"
vms_path="${repo_root}/vms_list.tf"
constants_path="${repo_root}/vms_constants.tf"
resources_path="${repo_root}/vms_resources.tf"
patch_dir="${repo_root}/patches"
talos_tf_path="${repo_root}/talos.tf"
talos_template_path="${repo_root}/templates/talos.template.tf"
controlplane_data_template_path="${repo_root}/templates/controlplane-data.template.tf"
worker_data_template_path="${repo_root}/templates/worker-data.template.tf"
machine_config_locals_template_path="${repo_root}/templates/machine-config-locals.template.tf"
talos_dir="$(dirname "${talos_tf_path}")"

if ! command -v awk >/dev/null 2>&1; then
  echo "Error: 'awk' is required but not found in PATH. Install awk or fix PATH." >&2
  exit 1
fi

if [[ ! -r "${template_path}" ]]; then
  echo "Error: template not readable: ${template_path}" >&2
  echo "Fix: ensure the file exists and is readable (git checkout or restore it)." >&2
  exit 1
fi

if [[ ! -r "${hostname_template_path}" ]]; then
  echo "Error: hostname template not readable: ${hostname_template_path}" >&2
  echo "Fix: ensure patches/hostname.template.yaml exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${qemu_template_path}" ]]; then
  echo "Error: qemu template not readable: ${qemu_template_path}" >&2
  echo "Fix: ensure patches/qemu.template.yaml exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${vms_path}" ]]; then
  echo "Error: VM list not readable: ${vms_path}" >&2
  echo "Fix: ensure vms_list.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${constants_path}" ]]; then
  echo "Error: constants file not readable: ${constants_path}" >&2
  echo "Fix: ensure vms_constants.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${resources_path}" ]]; then
  echo "Error: resources file not readable: ${resources_path}" >&2
  echo "Fix: ensure vms_resources.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -d "${patch_dir}" ]]; then
  echo "Error: patches directory not found: ${patch_dir}" >&2
  echo "Fix: create the directory (mkdir -p patches) or restore it from git." >&2
  exit 1
fi

if [[ -e "${talos_tf_path}" && ! -w "${talos_tf_path}" ]]; then
  echo "Error: talos.tf is not writable: ${talos_tf_path}" >&2
  echo "Fix: adjust permissions or remove the read-only file before regenerating." >&2
  exit 1
fi

if [[ ! -e "${talos_tf_path}" && ! -w "${talos_dir}" ]]; then
  echo "Error: talos.tf cannot be created in: ${talos_dir}" >&2
  echo "Fix: ensure the directory is writable." >&2
  exit 1
fi

if [[ ! -r "${talos_template_path}" ]]; then
  echo "Error: talos.tf template not readable: ${talos_template_path}" >&2
  echo "Fix: ensure templates/talos.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${controlplane_data_template_path}" ]]; then
  echo "Error: controlplane data template not readable: ${controlplane_data_template_path}" >&2
  echo "Fix: ensure templates/controlplane-data.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${worker_data_template_path}" ]]; then
  echo "Error: worker data template not readable: ${worker_data_template_path}" >&2
  echo "Fix: ensure templates/worker-data.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${machine_config_locals_template_path}" ]]; then
  echo "Error: machine config locals template not readable: ${machine_config_locals_template_path}" >&2
  echo "Fix: ensure templates/machine-config-locals.template.tf exists and is readable." >&2
  exit 1
fi

# Read network constants from vms_constants.tf.
net_size="$(awk -F'"' '/"net_size"/ { print $4; exit }' "${constants_path}")"
gateway="$(awk -F'"' '/"gateway"/ { print $4; exit }' "${constants_path}")"
dns_servers="$(awk -F'"' '/"dns_servers"/ { print $4; exit }' "${constants_path}")"
kernel_dns_servers_raw="$(awk -F'"' '/"kernel_dns_servers"/ { print $4; exit }' "${constants_path}")"
ntp_servers="$(awk -F'"' '/"ntp_servers"/ { print $4; exit }' "${constants_path}")"
disable_ipv6="$(awk -F'"' '/"disable_ipv6"/ { print $4; exit }' "${constants_path}")"
talos_version="$(awk -F'"' '/"version"/ { print $4; exit }' "${constants_path}")"
talos_factory_image_id="$(awk -F'"' '/"factory_image_id"/ { print $4; exit }' "${constants_path}")"
talos_discovery_service_disabled="$(awk -F'"' '/"discovery_service_disabled"/ { print $4; exit }' "${constants_path}")"
disk_by_id_prefix="$(awk -F'"' '/"disk_by_id_prefix"/ { print $4; exit }' "${constants_path}")"
proxy_url="$(awk -F'"' '/"proxy_url"/ { print $4; exit }' "${constants_path}")"
no_proxy_extra="$(awk -F'"' '/"no_proxy_extra"/ { print $4; exit }' "${constants_path}")"
cert_files_raw="$(awk -F'"' '/"cert_files"/ { print $4; exit }' "${constants_path}")"
legacy_proxy_ca_path="$(awk -F'"' '/"proxy_ca_path"/ { print $4; exit }' "${constants_path}")"

if [[ -z "${net_size}" || -z "${gateway}" || -z "${dns_servers}" ]]; then
  echo "Error: missing network constants in vms_constants.tf." >&2
  echo "Fix: ensure net_size, gateway, dns_servers exist under var.constants[\"network\"]." >&2
  exit 1
fi

if [[ -z "${talos_version}" || -z "${talos_factory_image_id}" ]]; then
  echo "Error: missing Talos constants in vms_constants.tf." >&2
  echo "Fix: ensure version and factory_image_id exist under var.constants[\"talos\"]." >&2
  exit 1
fi

if [[ -z "${talos_discovery_service_disabled}" ]]; then
  talos_discovery_service_disabled="true"
fi

if [[ -z "${disk_by_id_prefix}" ]]; then
  echo "Error: missing disk_by_id_prefix in vms_constants.tf." >&2
  echo "Fix: set vm.disk_by_id_prefix to match /dev/disk/by-id prefix (for example scsi-0QEMU_QEMU_HARDDISK_drive-scsi)." >&2
  exit 1
fi

yaml_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

is_ipv4_address() {
  local ip="$1"
  local a b c d extra
  IFS=. read -r a b c d extra <<< "${ip}"

  if [[ -n "${extra:-}" ]]; then
    return 1
  fi
  if [[ ! "${a}" =~ ^[0-9]+$ || ! "${b}" =~ ^[0-9]+$ || ! "${c}" =~ ^[0-9]+$ || ! "${d}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( a > 255 || b > 255 || c > 255 || d > 255 )); then
    return 1
  fi

  return 0
}

is_ipv6_address() {
  local ip="$1"
  [[ "${ip}" == *:* ]]
}

proxy_host_from_url() {
  local url="$1"
  local remainder

  remainder="${url#*://}"
  remainder="${remainder%%/*}"
  remainder="${remainder##*@}"

  if [[ "${remainder}" == \[* ]]; then
    remainder="${remainder#\[}"
    printf '%s' "${remainder%%]*}"
  else
    printf '%s' "${remainder%%:*}"
  fi
}

kernel_ip_value() {
  local value="$1"
  if is_ipv6_address "${value}" && [[ "${value}" != \[*\] ]]; then
    printf '[%s]' "${value}"
  else
    printf '%s' "${value}"
  fi
}

ipv4_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "${ip}"

  if [[ ! "${a}" =~ ^[0-9]+$ || ! "${b}" =~ ^[0-9]+$ || ! "${c}" =~ ^[0-9]+$ || ! "${d}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( a > 255 || b > 255 || c > 255 || d > 255 )); then
    return 1
  fi

  printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

int_to_ipv4() {
  local value="$1"
  printf '%d.%d.%d.%d\n' \
    $(( (value >> 24) & 255 )) \
    $(( (value >> 16) & 255 )) \
    $(( (value >> 8) & 255 )) \
    $(( value & 255 ))
}

network_cidr_from_ip() {
  local ip="$1"
  local prefix="$2"
  local ip_int
  local host_bits
  local mask
  local network

  if [[ ! "${prefix}" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
    return 1
  fi

  ip_int="$(ipv4_to_int "${ip}")" || return 1
  host_bits=$((32 - prefix))
  if (( host_bits == 32 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << host_bits) & 0xFFFFFFFF ))
  fi
  network=$(( ip_int & mask ))
  printf '%s/%s\n' "$(int_to_ipv4 "${network}")" "${prefix}"
}

proxy_url="$(trim "${proxy_url}")"
no_proxy_extra="$(trim "${no_proxy_extra}")"
kernel_dns_servers_raw="$(trim "${kernel_dns_servers_raw}")"
cert_files_raw="$(trim "${cert_files_raw}")"
legacy_proxy_ca_path="$(trim "${legacy_proxy_ca_path}")"
talos_discovery_service_disabled="$(trim "${talos_discovery_service_disabled}")"

if [[ -n "${proxy_url}" && ! "${proxy_url}" =~ ^https?:// ]]; then
  echo "Error: network.proxy_url must start with http:// or https:// (got ${proxy_url})." >&2
  echo "Fix: set proxy_url to a full URL such as http://proxy.example.com:3128." >&2
  exit 1
fi

case "${talos_discovery_service_disabled,,}" in
  "true"|"false")
    ;;
  *)
    echo "Error: talos.discovery_service_disabled must be \"true\" or \"false\" (got ${talos_discovery_service_disabled})." >&2
    echo "Fix: set talos.discovery_service_disabled to \"true\" or \"false\" in vms_constants.tf." >&2
    exit 1
    ;;
esac

if [[ -z "${cert_files_raw}" && -n "${legacy_proxy_ca_path}" ]]; then
  cert_files_raw="${legacy_proxy_ca_path}"
fi

# Load the machine patch template.
template="$(cat "${template_path}")"

# Basic template sanity check.
if [[ "${template}" != *'${ip}'* || "${template}" != *'${cidr}'* || "${template}" != *'${machine_disks_section}'* || "${template}" != *'${kubelet_extra_mounts_section}'* || "${template}" != *'${k8s_node_labels_section}'* || "${template}" != *'${proxy_env_section}'* || "${template}" != *'${cert_files_section}'* || "${template}" != *'${talos_discovery_service_disabled}'* ]]; then
  echo "Error: template is missing required placeholders (\${ip}, \${cidr}, \${machine_disks_section}, \${kubelet_extra_mounts_section}, \${k8s_node_labels_section}, \${proxy_env_section}, \${cert_files_section}, \${talos_discovery_service_disabled})." >&2
  echo "Fix: restore patches/machine.template.yaml or add the missing placeholders." >&2
  exit 1
fi

hostname_template="$(cat "${hostname_template_path}")"
if [[ "${hostname_template}" != *'${hostname}'* ]]; then
  echo "Error: hostname template is missing required placeholder (\${hostname})." >&2
  echo "Fix: restore patches/hostname.template.yaml or add the missing placeholder." >&2
  exit 1
fi

dns_servers_section=""
dns_servers_array=()
IFS=',' read -ra dns_list <<< "${dns_servers}"
for server in "${dns_list[@]}"; do
  server="${server#"${server%%[![:space:]]*}"}"
  server="${server%"${server##*[![:space:]]}"}"
  if [[ -n "${server}" ]]; then
    dns_servers_array+=("${server}")
    if [[ -n "${dns_servers_section}" ]]; then
      dns_servers_section+=", "
    fi
    dns_servers_section+="${server}"
  fi
done
if [[ -z "${dns_servers_section}" ]]; then
  echo "Error: dns_servers must contain at least one entry." >&2
  exit 1
fi

kernel_args=()
case "${disable_ipv6,,}" in
  "" | "true" | "1" | "yes")
    kernel_args+=("ipv6.disable=1")
    ;;
  "false" | "0" | "no")
    ;;
  *)
    echo "Error: invalid disable_ipv6 value in vms_constants.tf: ${disable_ipv6}" >&2
    echo "Fix: set network.disable_ipv6 to true/false, 1/0, or yes/no." >&2
    exit 1
    ;;
esac

ntp_servers_section=""
ntp_servers_array=()
if [[ -n "${ntp_servers}" ]]; then
  IFS=',' read -ra ntp_list <<< "${ntp_servers}"
  for server in "${ntp_list[@]}"; do
    server="${server#"${server%%[![:space:]]*}"}"
    server="${server%"${server##*[![:space:]]}"}"
    if [[ -n "${server}" ]]; then
      ntp_servers_array+=("${server}")
      if [[ -n "${ntp_servers_section}" ]]; then
        ntp_servers_section+=", "
      fi
      ntp_servers_section+="${server}"
    fi
  done
fi

qemu_template="$(cat "${qemu_template_path}")"
if [[ "${qemu_template}" != *'${talos_version}'* || "${qemu_template}" != *'${talos_factory_image_id}'* ]]; then
  echo "Error: qemu template is missing required placeholders (\${talos_version}, \${talos_factory_image_id})." >&2
  echo "Fix: restore patches/qemu.template.yaml or add the missing placeholders." >&2
  exit 1
fi

qemu_rendered="${qemu_template}"
qemu_rendered="${qemu_rendered//'${talos_version}'/${talos_version}}"
qemu_rendered="${qemu_rendered//'${talos_factory_image_id}'/${talos_factory_image_id}}"
qemu_out_path="${patch_dir}/qemu.yaml"
printf "%s\n" "${qemu_rendered}" > "${qemu_out_path}"
echo "wrote ${qemu_out_path}"

# Parse vms_list.tf for vm names and IPs, ignoring commented lines.
declare -A vm_ips
while IFS='|' read -r name ip; do
  if [[ -z "${name}" || -z "${ip}" ]]; then
    continue
  fi
  vm_ips["${name}"]="${ip}"
done < <(
  awk '
    function emit_pairs(obj_name, raw_line,   line, pair, key, val) {
      line = raw_line
      while (match(line, /"[^"]+"[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        pair = substr(line, RSTART, RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/".*/, "", key)
        sub(/^[^=]*=[[:space:]]*"/, "", pair)
        val = pair
        sub(/".*/, "", val)
        print obj_name "|" key "|" val
        line = substr(line, RSTART + RLENGTH)
      }
    }
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      next
    }
    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      ip = $0
      sub(/^[^"]*"/, "", ip)
      sub(/".*/, "", ip)
      print name "|" ip
      in_block = 0
      next
    }
    in_block && /}/ { in_block = 0 }
  ' "${vms_path}"
)

if [[ ${#vm_ips[@]} -eq 0 ]]; then
  echo "Error: no VMs found in vms_list.tf." >&2
  echo "Fix: add VM entries or remove commented-only entries." >&2
  exit 1
fi

proxy_env_section="{}"
cert_files_section="[]"
cert_file_paths=()
no_proxy_value=""
if [[ -n "${cert_files_raw}" ]]; then
  IFS=',' read -ra cert_file_entries <<< "${cert_files_raw}"
  for cert_file_path in "${cert_file_entries[@]}"; do
    cert_file_path="$(trim "${cert_file_path}")"
    if [[ -z "${cert_file_path}" ]]; then
      continue
    fi
    if [[ ! -r "${cert_file_path}" ]]; then
      echo "Error: cert_files entry is not readable: ${cert_file_path}" >&2
      echo "Fix: point network.cert_files to readable PEM certificate paths, separated by commas." >&2
      exit 1
    fi
    cert_file_paths+=("${cert_file_path}")
  done
fi

if [[ -n "${proxy_url}" ]]; then
  kernel_args+=("talos.environment=http_proxy=${proxy_url}")
  kernel_args+=("talos.environment=https_proxy=${proxy_url}")

  declare -A seen_no_proxy_entries=()
  no_proxy_entries=()

  add_no_proxy_entry() {
    local value
    value="$(trim "${1:-}")"
    if [[ -z "${value}" || -n "${seen_no_proxy_entries[${value}]:-}" ]]; then
      return
    fi
    no_proxy_entries+=("${value}")
    seen_no_proxy_entries["${value}"]=1
  }

  local_network_cidr="$(network_cidr_from_ip "${gateway}" "${net_size}" 2>/dev/null || true)"
  if [[ -z "${local_network_cidr}" ]]; then
    echo "Error: failed to derive the local network CIDR from gateway=${gateway} and net_size=${net_size}." >&2
    echo "Fix: ensure network.gateway is a valid IPv4 address and network.net_size is a prefix length such as 24." >&2
    exit 1
  fi

  add_no_proxy_entry "localhost"
  add_no_proxy_entry "127.0.0.1"
  add_no_proxy_entry "::1"
  add_no_proxy_entry "${gateway}"
  add_no_proxy_entry "${local_network_cidr}"

  while IFS= read -r value; do
    add_no_proxy_entry "${value}"
  done < <(printf "%s\n" "${!vm_ips[@]}" | sort)

  while IFS= read -r value; do
    add_no_proxy_entry "${value}"
  done < <(printf "%s\n" "${vm_ips[@]}" | sort -u)

  add_no_proxy_entry "kubernetes"
  add_no_proxy_entry "kubernetes.default"
  add_no_proxy_entry "kubernetes.default.svc"
  add_no_proxy_entry "kubernetes.default.svc.cluster.local"
  add_no_proxy_entry "svc"
  add_no_proxy_entry ".svc"
  add_no_proxy_entry "svc.cluster.local"
  add_no_proxy_entry ".svc.cluster.local"
  add_no_proxy_entry "cluster.local"
  add_no_proxy_entry ".cluster.local"

  k8s_net_domain=""
  k8s_net_constants_path="${repo_root}/k8s-net/constants.tf"
  if [[ "${skip_k8s_net}" != "true" && -r "${k8s_net_constants_path}" ]]; then
    k8s_net_domain="$(awk -F'"' '/^[[:space:]]*domain[[:space:]]*=/{print $2; exit}' "${k8s_net_constants_path}")"
    k8s_net_ingress_ip="$(awk -F'"' '/^[[:space:]]*ingress_lb_ip[[:space:]]*=/{print $2; exit}' "${k8s_net_constants_path}")"
    if [[ -n "${k8s_net_ingress_ip}" ]]; then
      add_no_proxy_entry "${k8s_net_ingress_ip}"
    fi
    if [[ -n "${k8s_net_domain}" ]]; then
      while IFS= read -r hostname; do
        add_no_proxy_entry "${hostname}"
      done < <(
        awk -v domain="${k8s_net_domain}" -v skip_portainer="${skip_portainer}" -v skip_ceph="${skip_ceph}" -F'"' '
          /_hostname[[:space:]]*=/ {
            key=$1
            gsub(/^[[:space:]]+/, "", key)
            gsub(/[[:space:]]*=[[:space:]]*$/, "", key)
            if (skip_portainer == "true" && key == "portainer_hostname") next
            if (skip_ceph == "true" && key == "ceph_hostname") next
            val=$2
            gsub("\\$\\{local.domain\\}", domain, val)
            print val
          }
        ' "${k8s_net_constants_path}"
      )
    fi
  fi

  monitoring_constants_path="${repo_root}/monitoring/constants.tf"
  if [[ "${skip_monitoring}" != "true" && -r "${monitoring_constants_path}" && -n "${k8s_net_domain}" ]]; then
    while IFS= read -r hostname; do
      add_no_proxy_entry "${hostname}"
    done < <(
      awk -v domain="${k8s_net_domain}" -F'"' '/_hostname[[:space:]]*=/{val=$2; gsub("\\$\\{local.domain\\}", domain, val); print val}' "${monitoring_constants_path}"
    )
  fi

  if [[ -n "${no_proxy_extra}" ]]; then
    IFS=',' read -ra extra_no_proxy_entries <<< "${no_proxy_extra}"
    for value in "${extra_no_proxy_entries[@]}"; do
      add_no_proxy_entry "${value}"
    done
  fi

  no_proxy_value=""
  for value in "${no_proxy_entries[@]}"; do
    if [[ -n "${no_proxy_value}" ]]; then
      no_proxy_value+=","
    fi
    no_proxy_value+="${value}"
  done

  proxy_env_section=$'\n'
  proxy_env_section+=$'    http_proxy: "'"$(yaml_escape "${proxy_url}")"$'"\n'
  proxy_env_section+=$'    https_proxy: "'"$(yaml_escape "${proxy_url}")"$'"\n'
  proxy_env_section+=$'    no_proxy: "'"$(yaml_escape "${no_proxy_value}")"$'"'
fi

proxy_host=""
proxy_uses_hostname=false
if [[ -n "${proxy_url}" ]]; then
  proxy_host="$(proxy_host_from_url "${proxy_url}")"
  if [[ -n "${proxy_host}" ]] && ! is_ipv4_address "${proxy_host}" && ! is_ipv6_address "${proxy_host}"; then
    proxy_uses_hostname=true
  fi
fi

if [[ "${proxy_uses_hostname}" == "true" ]]; then
  kernel_dns_servers_effective="${kernel_dns_servers_raw}"
  if [[ -z "${kernel_dns_servers_effective}" ]]; then
    kernel_dns_servers_effective="${dns_servers}"
  fi

  kernel_dns_servers_array=()
  IFS=',' read -ra kernel_dns_list <<< "${kernel_dns_servers_effective}"
  for server in "${kernel_dns_list[@]}"; do
    server="$(trim "${server}")"
    if [[ -z "${server}" ]]; then
      continue
    fi
    if ! is_ipv4_address "${server}" && ! is_ipv6_address "${server}"; then
      echo "Error: kernel DNS entries must be IP addresses when network.proxy_url uses a hostname (got ${server})." >&2
      echo "Fix: set network.kernel_dns_servers or network.dns_servers to IP addresses reachable during early Talos boot." >&2
      exit 1
    fi
    kernel_dns_servers_array+=("${server}")
  done

  if [[ ${#kernel_dns_servers_array[@]} -eq 0 ]]; then
    echo "Error: network.proxy_url uses a hostname, but no kernel DNS servers were found." >&2
    echo "Fix: set network.kernel_dns_servers or network.dns_servers to at least one reachable DNS server IP." >&2
    exit 1
  fi

  kernel_dns_0="$(kernel_ip_value "${kernel_dns_servers_array[0]}")"
  kernel_dns_1=""
  if [[ ${#kernel_dns_servers_array[@]} -ge 2 ]]; then
    kernel_dns_1="$(kernel_ip_value "${kernel_dns_servers_array[1]}")"
  fi
  kernel_ntp_0=""
  if [[ ${#ntp_servers_array[@]} -ge 1 ]]; then
    if is_ipv4_address "${ntp_servers_array[0]}" || is_ipv6_address "${ntp_servers_array[0]}"; then
      kernel_ntp_0="$(kernel_ip_value "${ntp_servers_array[0]}")"
    fi
  fi
  kernel_args+=("ip=:::::::${kernel_dns_0}:${kernel_dns_1}:${kernel_ntp_0}")
fi

if [[ ${#kernel_args[@]} -gt 0 ]]; then
  extra_kernel_args_section=$'\n'
  for kernel_arg in "${kernel_args[@]}"; do
    extra_kernel_args_section+=$'      - "'"$(yaml_escape "${kernel_arg}")"$'"\n'
  done
  extra_kernel_args_section="${extra_kernel_args_section%$'\n'}"
else
  extra_kernel_args_section=" []"
fi

if [[ ${#cert_file_paths[@]} -gt 0 ]]; then
  cert_files_section=$'\n'
  for cert_file_path in "${cert_file_paths[@]}"; do
    cert_file_content=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
      cert_file_content+=$'\n        '"${line}"
    done < "${cert_file_path}"
    if [[ -z "${cert_file_content}" ]]; then
      echo "Error: cert_files entry is empty: ${cert_file_path}" >&2
      echo "Fix: provide PEM certificates with content, or remove empty paths from network.cert_files." >&2
      exit 1
    fi

    cert_files_section+=$'    - content: |'"${cert_file_content}"$'\n'
    cert_files_section+=$'      permissions: 0644\n'
    cert_files_section+=$'      path: /etc/ssl/certs/ca-certificates\n'
    cert_files_section+=$'      op: append\n'
  done
  cert_files_section="${cert_files_section%$'\n'}"
fi

# Build VM role lists from vms_list.tf.
declare -A vm_resource_types
declare -A resource_k8s_nodes
controlplane_names=()
worker_names=()

while IFS='|' read -r resource_type k8s_node; do
  if [[ -z "${resource_type}" || -z "${k8s_node}" ]]; then
    continue
  fi
  resource_k8s_nodes["${resource_type}"]="${k8s_node}"
done < <(
  awk '
    function emit_pairs(obj_name, raw_line,   line, pair, key, val) {
      line = raw_line
      while (match(line, /"[^"]+"[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        pair = substr(line, RSTART, RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/".*/, "", key)
        sub(/^[^=]*=[[:space:]]*"/, "", pair)
        val = pair
        sub(/".*/, "", val)
        print obj_name "|" key "|" val
        line = substr(line, RSTART + RLENGTH)
      }
    }
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
      if (name != "" && k8s != "") {
        print name "|" k8s
      }
      in_block = 0
    }
  ' "${resources_path}"
)

declare -A resource_labels
while IFS='|' read -r resource_type label_key label_value; do
  if [[ -z "${resource_type}" || -z "${label_key}" ]]; then
    continue
  fi
  resource_labels["${resource_type}|${label_key}"]="${label_value}"
done < <(
  awk '
    function emit_pairs(obj_name, raw_line,   line, pair, key, val) {
      line = raw_line
      while (match(line, /"[^"]+"[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        pair = substr(line, RSTART, RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/".*/, "", key)
        sub(/^[^=]*=[[:space:]]*"/, "", pair)
        val = pair
        sub(/".*/, "", val)
        print obj_name "|" key "|" val
        line = substr(line, RSTART + RLENGTH)
      }
    }
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      in_labels = 0
      next
    }
    in_block && match($0, /k8s_labels[[:space:]]*=[[:space:]]*{/) {
      if ($0 ~ /}/) {
        emit_pairs(name, $0)
        in_labels = 0
      } else {
        in_labels = 1
      }
      next
    }
    in_block && in_labels {
      if ($0 ~ /^[[:space:]]*}/) {
        in_labels = 0
        next
      }
      emit_pairs(name, $0)
      next
    }
    in_block && /^[[:space:]]*}/ {
      in_block = 0
    }
  ' "${resources_path}"
)

declare -A vm_labels
while IFS='|' read -r vm_name label_key label_value; do
  if [[ -z "${vm_name}" || -z "${label_key}" ]]; then
    continue
  fi
  vm_labels["${vm_name}|${label_key}"]="${label_value}"
done < <(
  awk '
    function emit_pairs(obj_name, raw_line,   line, pair, key, val) {
      line = raw_line
      while (match(line, /"[^"]+"[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        pair = substr(line, RSTART, RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/".*/, "", key)
        sub(/^[^=]*=[[:space:]]*"/, "", pair)
        val = pair
        sub(/".*/, "", val)
        print obj_name "|" key "|" val
        line = substr(line, RSTART + RLENGTH)
      }
    }
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      in_labels = 0
      next
    }
    in_block && match($0, /k8s_labels[[:space:]]*=[[:space:]]*{/) {
      if ($0 ~ /}/) {
        emit_pairs(name, $0)
        in_labels = 0
      } else {
        in_labels = 1
      }
      next
    }
    in_block && in_labels {
      if ($0 ~ /^[[:space:]]*}/) {
        in_labels = 0
        next
      }
      emit_pairs(name, $0)
      next
    }
    in_block && /^[[:space:]]*}/ {
      in_block = 0
    }
  ' "${vms_path}"
)

declare -A global_k8s_labels
while IFS='|' read -r label_key label_value; do
  if [[ -z "${label_key}" ]]; then
    continue
  fi
  global_k8s_labels["${label_key}"]="${label_value}"
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*"?k8s"?[[:space:]]*=[[:space:]]*{/ {
      in_k8s = 1
      k8s_depth = 1
      next
    }
    in_k8s && /^[[:space:]]*"?labels"?[[:space:]]*=[[:space:]]*{/ {
      in_labels = 1
      labels_depth = 1
      next
    }
    in_k8s && in_labels {
      if (match($0, /"[^"]+"[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        line = $0
        sub(/^[[:space:]]*"/, "", line)
        key = line
        sub(/".*/, "", key)
        sub(/^[^=]*=[[:space:]]*"/, "", line)
        val = line
        sub(/".*/, "", val)
        print key "|" val
      }
      opens = gsub(/{/, "{", $0)
      closes = gsub(/}/, "}", $0)
      labels_depth += (opens - closes)
      if (labels_depth <= 0) {
        in_labels = 0
      }
      next
    }
    in_k8s {
      opens = gsub(/{/, "{", $0)
      closes = gsub(/}/, "}", $0)
      k8s_depth += (opens - closes)
      if (k8s_depth <= 0) {
        in_k8s = 0
        in_labels = 0
      }
    }
  ' "${constants_path}"
)

while IFS='|' read -r name resource_type; do
  if [[ -z "${name}" || -z "${resource_type}" ]]; then
    continue
  fi
  vm_resource_types["${name}"]="${resource_type}"
  if [[ -v "resource_k8s_nodes[${resource_type}]" ]]; then
    k8s_node="${resource_k8s_nodes[${resource_type}]}"
  else
    k8s_node=""
  fi
  if [[ -z "${k8s_node}" ]]; then
    echo "Error: resource type '${resource_type}' is not defined in vms_resources.tf." >&2
    echo "Fix: add a resources entry for '${resource_type}' with k8s_node and sizing." >&2
    exit 1
  fi
  if [[ "${k8s_node}" == "controlplane" ]]; then
    controlplane_names+=("${name}")
  elif [[ "${k8s_node}" == "worker" ]]; then
    worker_names+=("${name}")
  else
    echo "Error: invalid k8s_node '${k8s_node}' for resource type ${resource_type}." >&2
    echo "Fix: set k8s_node to 'controlplane' or 'worker' in vms_resources.tf." >&2
    exit 1
  fi
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      resource = ""
      next
    }
    in_block && match($0, /type[[:space:]]*=[[:space:]]*"[^"]+"/) {
      resource = $0
      sub(/^[^"]*"/, "", resource)
      sub(/".*/, "", resource)
    }
    in_block && /}/ {
      if (resource != "") {
        print name "|" resource
      }
      in_block = 0
    }
  ' "${vms_path}"
)

if [[ ${#controlplane_names[@]} -eq 0 || ${#worker_names[@]} -eq 0 ]]; then
  echo "Error: could not detect controlplane/worker VM types in vms_list.tf." >&2
  echo "Fix: ensure each VM block has type = \"controlplane\" or type = \"worker\"." >&2
  exit 1
fi

for name in "${!vm_ips[@]}"; do
  if [[ -z "${vm_resource_types[${name}]:-}" ]]; then
    echo "Error: VM ${name} has no type in vms_list.tf." >&2
    echo "Fix: add type = \"<resource-type>\" for ${name}." >&2
    exit 1
  fi
done

declare -A disk_mounts
declare -A disk_counts
while IFS='|' read -r vm_type size mount; do
  count="${disk_counts[${vm_type}]:-0}"
  if [[ -n "${mount}" ]]; then
    disk_mounts["${vm_type}|${count}"]="${mount}"
  fi
  disk_counts["${vm_type}"]=$((count + 1))
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      current = $0
      sub(/^[^"]*"/, "", current)
      sub(/".*/, "", current)
      in_block = 1
      next
    }
    in_block && match($0, /disks[[:space:]]*=/) { in_disks = 1 }
    in_block && in_disks {
      line = $0
      gsub(/#.*/, "", line)
      if (line ~ /]/) { in_disks = 0 }
      if (line ~ /size[[:space:]]*=/) {
        gsub(/[{}]/, "", line)
        size = ""
        mount = ""
        n = split(line, parts, ",")
        for (i = 1; i <= n; i++) {
          part = parts[i]
          gsub(/^[[:space:]]+/, "", part)
          gsub(/[[:space:]]+$/, "", part)
          if (part ~ /^size[[:space:]]*=/) {
            sub(/^size[[:space:]]*=/, "", part)
            gsub(/[[:space:]]*/, "", part)
            size = part
          }
          if (part ~ /^mount[[:space:]]*=/) {
            sub(/^mount[[:space:]]*=/, "", part)
            gsub(/^[[:space:]]*"/, "", part)
            gsub(/"[[:space:]]*$/, "", part)
            mount = part
          }
        }
        if (size != "") {
          print current "|" size "|" mount
        }
      }
      next
    }
    in_block && /}/ { in_block = 0 }
  ' "${resources_path}"
)

# Render per-VM machine patch files from the template.
for name in "${!vm_ips[@]}"; do
  ip="${vm_ips[${name}]}"
  if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Error: invalid IP format for ${name}: ${ip}" >&2
    echo "Fix: set a valid IPv4 address in vms_list.tf for ${name}." >&2
    exit 1
  fi
  resource_type="${vm_resource_types[${name}]}"
  disks_block=""
  kubelet_mounts_block=""
  k8s_node_labels_block=""
  declare -A merged_labels=()
  for key in "${!global_k8s_labels[@]}"; do
    merged_labels["${key}"]="${global_k8s_labels[${key}]}"
  done
  disk_total="${disk_counts[${resource_type}]:-0}"
  for ((idx=0; idx<disk_total; idx++)); do
    mount_path="${disk_mounts[${resource_type}|${idx}]:-}"
    if [[ -z "${mount_path}" ]]; then
      continue
    fi
    if [[ "${mount_path}" != /var/* ]]; then
      echo "Error: mount path must be under /var for ${resource_type} disk index ${idx} (got ${mount_path})." >&2
      echo "Fix: use a /var-based mountpoint like /var/mnt/... or /var/lib/...." >&2
      exit 1
    fi
    device="/dev/disk/by-id/${disk_by_id_prefix}${idx}"
    disks_block+=$'\n    - device: '"${device}"$'\n      partitions:\n        - mountpoint: '"${mount_path}"$'\n          size: 0 # Use full disk'
    kubelet_mounts_block+=$'\n      - destination: '"${mount_path}"$'\n        type: bind\n        source: '"${mount_path}"$'\n        options:\n          - bind\n          - rshared\n          - rw'
  done
  if [[ -n "${disks_block}" ]]; then
    machine_disks_section="${disks_block}"
  else
    machine_disks_section=" []"
  fi
  if [[ -n "${kubelet_mounts_block}" ]]; then
    kubelet_extra_mounts_section="${kubelet_mounts_block}"
  else
    kubelet_extra_mounts_section=" []"
  fi

  for key in "${!resource_labels[@]}"; do
    if [[ "${key}" == "${resource_type}|"* ]]; then
      label_key="${key#${resource_type}|}"
      merged_labels["${label_key}"]="${resource_labels[${key}]}"
    fi
  done
  for key in "${!vm_labels[@]}"; do
    if [[ "${key}" == "${name}|"* ]]; then
      label_key="${key#${name}|}"
      merged_labels["${label_key}"]="${vm_labels[${key}]}"
    fi
  done
  if [[ ${#merged_labels[@]} -gt 0 ]]; then
    while IFS= read -r label_key; do
      label_value="${merged_labels[${label_key}]}"
      k8s_node_labels_block+=$'\n    "'"$(yaml_escape "${label_key}")"'": "'"$(yaml_escape "${label_value}")"'"'
    done < <(printf "%s\n" "${!merged_labels[@]}" | sort)
    k8s_node_labels_section="${k8s_node_labels_block}"
  else
    k8s_node_labels_section=" {}"
  fi

  rendered="${template}"
  rendered="${rendered//'${ip}'/${ip}}"
  rendered="${rendered//'${cidr}'/${net_size}}"
  rendered="${rendered//'${gateway}'/${gateway}}"
  rendered="${rendered//'${dns_servers_section}'/${dns_servers_section}}"
  rendered="${rendered//'${ntp_servers_section}'/${ntp_servers_section}}"
  rendered="${rendered//'${extra_kernel_args_section}'/${extra_kernel_args_section}}"
  rendered="${rendered//'${machine_disks_section}'/${machine_disks_section}}"
  rendered="${rendered//'${kubelet_extra_mounts_section}'/${kubelet_extra_mounts_section}}"
  rendered="${rendered//'${k8s_node_labels_section}'/${k8s_node_labels_section}}"
  rendered="${rendered//'${proxy_env_section}'/${proxy_env_section}}"
  rendered="${rendered//'${cert_files_section}'/${cert_files_section}}"
  rendered="${rendered//'${talos_discovery_service_disabled}'/${talos_discovery_service_disabled,,}}"
  out_path="${patch_dir}/machine-${name}.yaml"
  printf "%s\n" "${rendered}" > "${out_path}"
  echo "wrote ${out_path}"

  hostname_rendered="${hostname_template//'${hostname}'/${name}}"
  hostname_out_path="${patch_dir}/hostname-${name}.yaml"
  printf "%s\n" "${hostname_rendered}" > "${hostname_out_path}"
  echo "wrote ${hostname_out_path}"
done

# Remove stale patch files not present in vms_list.tf.
for path in "${patch_dir}"/machine-*.yaml; do
  [[ -e "${path}" ]] || continue
  base="$(basename "${path}")"
  name="${base#machine-}"
  name="${name%.yaml}"
  if [[ -z "${vm_ips[${name}]:-}" ]]; then
    rm -f "${path}"
    echo "removed ${path}"
  fi
done

for path in "${patch_dir}"/network-*.yaml; do
  [[ -e "${path}" ]] || continue
  rm -f "${path}"
  echo "removed ${path}"
done

for path in "${patch_dir}"/hostname-*.yaml; do
  [[ -e "${path}" ]] || continue
  base="$(basename "${path}")"
  name="${base#hostname-}"
  name="${name%.yaml}"
  if [[ -z "${vm_ips[${name}]:-}" ]]; then
    rm -f "${path}"
    echo "removed ${path}"
  fi
done

primary_controlplane="${controlplane_names[0]}"
if [[ -z "${primary_controlplane}" ]]; then
  echo "Error: unable to determine primary control plane VM." >&2
  echo "Fix: ensure vms_list.tf contains at least one controlplane entry." >&2
  exit 1
fi

controlplane_data_template="$(cat "${controlplane_data_template_path}")"
worker_data_template="$(cat "${worker_data_template_path}")"
machine_config_locals_template="$(cat "${machine_config_locals_template_path}")"

if [[ "${controlplane_data_template}" != *"__SAFE_NAME__"* || \
      "${controlplane_data_template}" != *"__NAME__"* || \
      "${controlplane_data_template}" != *"__PRIMARY_CONTROLPLANE__"* ]]; then
  echo "Error: controlplane data template is missing required placeholders." >&2
  echo "Fix: add __SAFE_NAME__, __NAME__, and __PRIMARY_CONTROLPLANE__ to templates/controlplane-data.template.tf." >&2
  exit 1
fi

if [[ "${worker_data_template}" != *"__SAFE_NAME__"* || \
      "${worker_data_template}" != *"__NAME__"* || \
      "${worker_data_template}" != *"__PRIMARY_CONTROLPLANE__"* ]]; then
  echo "Error: worker data template is missing required placeholders." >&2
  echo "Fix: add __SAFE_NAME__, __NAME__, and __PRIMARY_CONTROLPLANE__ to templates/worker-data.template.tf." >&2
  exit 1
fi

if [[ "${machine_config_locals_template}" != *"__CONTROLPLANE_LOCALS__"* || \
      "${machine_config_locals_template}" != *"__WORKER_LOCALS__"* ]]; then
  echo "Error: machine config locals template is missing required placeholders." >&2
  echo "Fix: add __CONTROLPLANE_LOCALS__ and __WORKER_LOCALS__ to templates/machine-config-locals.template.tf." >&2
  exit 1
fi

controlplane_blocks=()
for name in "${controlplane_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  block="${controlplane_data_template}"
  block="${block//__SAFE_NAME__/${safe_name}}"
  block="${block//__NAME__/${name}}"
  block="${block//__PRIMARY_CONTROLPLANE__/${primary_controlplane}}"
  block="${block%$'\n'}"
  controlplane_blocks+=("${block}")
done
controlplane_data="$(printf "%s\n\n" "${controlplane_blocks[@]}")"
controlplane_data="${controlplane_data%$'\n\n'}"
controlplane_data+=$'\n'

worker_blocks=()
for name in "${worker_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  block="${worker_data_template}"
  block="${block//__SAFE_NAME__/${safe_name}}"
  block="${block//__NAME__/${name}}"
  block="${block//__PRIMARY_CONTROLPLANE__/${primary_controlplane}}"
  block="${block%$'\n'}"
  worker_blocks+=("${block}")
done
worker_data="$(printf "%s\n\n" "${worker_blocks[@]}")"
worker_data="${worker_data%$'\n\n'}"
worker_data+=$'\n'

controlplane_locals=""
for name in "${controlplane_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  controlplane_locals+="    \"${name}\" = format(\"%s\\n---\\n%s\\n\", trimspace(join(\"\\\\n---\\\\n\", [for doc in split(\"\\\\n---\\\\n\", data.talos_machine_configuration.machineconfig_${safe_name}.machine_configuration) : doc if !startswith(doc, \"apiVersion: v1alpha1\\\\nkind: HostnameConfig\\\\n\")])), trimspace(file(\"\${path.module}/patches/hostname-${name}.yaml\")))"$'\n'
done

worker_locals=""
for name in "${worker_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  worker_locals+="    \"${name}\" = format(\"%s\\n---\\n%s\\n\", trimspace(join(\"\\\\n---\\\\n\", [for doc in split(\"\\\\n---\\\\n\", data.talos_machine_configuration.machineconfig_${safe_name}.machine_configuration) : doc if !startswith(doc, \"apiVersion: v1alpha1\\\\nkind: HostnameConfig\\\\n\")])), trimspace(file(\"\${path.module}/patches/hostname-${name}.yaml\")))"$'\n'
done

controlplane_locals="${controlplane_locals%$'\n'}"
worker_locals="${worker_locals%$'\n'}"
locals_block="${machine_config_locals_template}"
locals_block="${locals_block//__CONTROLPLANE_LOCALS__/${controlplane_locals}}"
locals_block="${locals_block//__WORKER_LOCALS__/${worker_locals}}"
locals_block="${locals_block%$'\n'}"
locals_block+=$'\n'

talos_template="$(cat "${talos_template_path}")"
if [[ "${talos_template}" != *"__CONTROLPLANE_DATA__"* || \
      "${talos_template}" != *"__WORKER_DATA__"* || \
      "${talos_template}" != *"__MACHINE_CONFIG_LOCALS__"* || \
      "${talos_template}" != *"__CONTROLPLANE_PRIMARY__"* ]]; then
  echo "Error: talos.tf template is missing required placeholders." >&2
  echo "Fix: ensure templates/talos.template.tf contains __CONTROLPLANE_PRIMARY__, __CONTROLPLANE_DATA__, __WORKER_DATA__, and __MACHINE_CONFIG_LOCALS__." >&2
  exit 1
fi

talos_rendered="${talos_template//__CONTROLPLANE_PRIMARY__/${primary_controlplane}}"
talos_rendered="${talos_rendered//__CONTROLPLANE_DATA__/${controlplane_data}}"
talos_rendered="${talos_rendered//__WORKER_DATA__/${worker_data}}"
talos_rendered="${talos_rendered//__MACHINE_CONFIG_LOCALS__/${locals_block}}"
talos_rendered="$(printf "%s" "${talos_rendered}" | awk '
  BEGIN { blank = 0 }
  /^$/ {
    blank++
    if (blank == 1) { print }
    next
  }
  { blank = 0; print }
')"

printf "%s" "${talos_rendered}" > "${talos_tf_path}"
echo "generated ${talos_tf_path}"
