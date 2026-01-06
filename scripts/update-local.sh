#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: update-local.sh [options]

Installs the k8s-net root CA into the local trust store.
This script does NOT call sudo; run it with sudo if required.

Options:
  -a, --all            Apply all non-destructive actions.
  -c, --root-ca       Install the root CA into the system trust store.
  -e, --etc-hosts     Update /etc/hosts with cluster hostnames.
      --del-etc-hosts Remove the managed /etc/hosts entry.
  -h, --help          Show this help message.
USAGE
}

install_root_ca=false
update_hosts=false
delete_hosts=false
apply_all=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)
      apply_all=true
      shift
      ;;
    -c|--root-ca)
      install_root_ca=true
      shift
      ;;
    -e|--etc-hosts)
      update_hosts=true
      shift
      ;;
    --del-etc-hosts)
      delete_hosts=true
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

if [[ "${apply_all}" == "true" ]]; then
  install_root_ca=true
  update_hosts=true
fi

if [[ "${install_root_ca}" == "false" && "${update_hosts}" == "false" && "${delete_hosts}" == "false" ]]; then
  usage
  exit 0
fi

if [[ "${update_hosts}" == "true" && "${delete_hosts}" == "true" ]]; then
  error "Cannot use --etc-hosts and --del-etc-hosts together."
  exit 1
fi

if [[ "${apply_all}" == "true" && "${delete_hosts}" == "true" ]]; then
  error "Cannot use --all with --del-etc-hosts."
  exit 1
fi

require_cmd uname

# Ensure root only when a write is required.
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script needs to run as root for this operation."
    error "Run: sudo ${script_dir}/update-local.sh"
    exit 1
  fi
}

# Shared /etc/hosts context and helpers.
hosts_file="/etc/hosts"
start_marker="# BEGIN pve-k8s-talos"
end_marker="# END pve-k8s-talos"

# Rewrite /etc/hosts without the managed block.
write_hosts_without_block() {
  local dest="$1"
  awk -v start="^${start_marker}$" -v end="^${end_marker}$" '
    $0 ~ start {skip=1; next}
    $0 ~ end {skip=0; next}
    !skip {print}
  ' "${hosts_file}" > "${dest}"
}

if [[ "${install_root_ca}" == "true" ]]; then
  require_cmd awk
  require_cmd cp

  # Load domain and cert path from k8s-net constants.
  constants_path="${repo_root}/k8s-net/constants.tf"
  if [[ ! -r "${constants_path}" ]]; then
    error "Cannot read ${constants_path}. Create it from k8s-net/constants.tf.sample."
    exit 1
  fi

  domain="$(awk -F'"' '/^[[:space:]]*domain[[:space:]]*=/{print $2; exit}' "${constants_path}")"
  if [[ -z "${domain}" ]]; then
    error "Failed to parse domain from ${constants_path}."
    exit 1
  fi

  cert_path="${repo_root}/k8s-net/${domain}.pem"
  if [[ ! -r "${cert_path}" ]]; then
    error "Root CA not found: ${cert_path}"
    error "Generate it by applying k8s-net first."
    exit 1
  fi

  require_root

  os_name="$(uname -s)"
  case "${os_name}" in
    Darwin)
      require_cmd security
      message "Installing Root CA on macOS..."
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${cert_path}"
      ;;
    Linux)
      if command -v update-ca-certificates >/dev/null 2>&1; then
        message "Installing Root CA on Debian/Ubuntu..."
        cp "${cert_path}" "/usr/local/share/ca-certificates/${domain}.crt"
        update-ca-certificates
      elif command -v update-ca-trust >/dev/null 2>&1; then
        message "Installing Root CA on RHEL/Fedora/CentOS..."
        cp "${cert_path}" "/etc/pki/ca-trust/source/anchors/${domain}.crt"
        update-ca-trust
      else
        error "Unsupported Linux distro: update-ca-certificates/update-ca-trust not found."
        exit 1
      fi
      ;;
    *)
      error "Unsupported OS: ${os_name}"
      exit 1
      ;;
  esac

  message "Root CA installed for ${domain}."
fi

if [[ "${update_hosts}" == "true" ]]; then
  require_cmd awk
  require_cmd mktemp
  require_cmd sort

  # Load hostnames and ingress IP from constants.
  constants_path="${repo_root}/k8s-net/constants.tf"
  if [[ ! -r "${constants_path}" ]]; then
    error "Cannot read ${constants_path}. Create it from k8s-net/constants.tf.sample."
    exit 1
  fi

  domain="$(awk -F'"' '/^[[:space:]]*domain[[:space:]]*=/{print $2; exit}' "${constants_path}")"
  if [[ -z "${domain}" ]]; then
    error "Failed to parse domain from ${constants_path}."
    exit 1
  fi

  ingress_ip="$(awk -F'"' '/^[[:space:]]*ingress_lb_ip[[:space:]]*=/{print $2; exit}' "${constants_path}")"
  if [[ -z "${ingress_ip}" ]]; then
    error "Failed to parse ingress_lb_ip from ${constants_path}."
    exit 1
  fi

  monitoring_constants="${repo_root}/monitoring/constants.tf"
  if [[ ! -r "${monitoring_constants}" ]]; then
    error "Cannot read ${monitoring_constants}. Create it from monitoring/constants.tf.sample."
    exit 1
  fi
  k8s_net_hostnames="$(awk -v domain="${domain}" -F'"' '/_hostname[[:space:]]*=/{val=$2; gsub("\\$\\{local.domain\\}", domain, val); print val}' "${constants_path}")"
  monitoring_hostnames="$(awk -v domain="${domain}" -F'"' '/_hostname[[:space:]]*=/{val=$2; gsub("\\$\\{local.domain\\}", domain, val); print val}' "${monitoring_constants}")"

  hostnames="$(printf "%s\n%s\n" "${k8s_net_hostnames}" "${monitoring_hostnames}" | awk 'NF' | sort -u)"
  if [[ -z "${hostnames}" ]]; then
    error "No hostnames found in ${constants_path} or ${monitoring_constants}."
    exit 1
  fi

  desired_block="$(printf "%s\n%s %s\n%s\n" "${start_marker}" "${ingress_ip}" "$(printf "%s" "${hostnames}" | paste -sd' ' -)" "${end_marker}")"
  current_block="$(awk -v start="^${start_marker}$" -v end="^${end_marker}$" '
    $0 ~ start {print; in_block=1; next}
    in_block {print}
    $0 ~ end {in_block=0}
  ' "${hosts_file}")"
  if [[ "${current_block}" == "${desired_block}" ]]; then
    message "/etc/hosts already contains the desired entry."
    update_hosts="false"
  fi

  # Only require root when a change is needed.
  if [[ "${update_hosts}" == "true" ]]; then
    require_root
  fi
  tmp_file="$(mktemp)"
  write_hosts_without_block "${tmp_file}"

  {
    printf "%s\n" "${start_marker}"
    printf "%s " "${ingress_ip}"
    printf "%s" "${hostnames}" | paste -sd' ' -
    printf "\n%s\n" "${end_marker}"
  } >> "${tmp_file}"

  if [[ "${update_hosts}" == "true" ]]; then
    cp "${tmp_file}" "${hosts_file}"
    message "/etc/hosts updated with ${ingress_ip} for $(printf "%s" "${hostnames}" | wc -w | tr -d ' ') hostnames."
  fi
  rm -f "${tmp_file}"
fi

if [[ "${delete_hosts}" == "true" ]]; then
  require_cmd awk
  require_cmd cp
  require_cmd mktemp

  # Skip privilege escalation if the block is absent.
  if ! grep -qF "${start_marker}" "${hosts_file}" || ! grep -qF "${end_marker}" "${hosts_file}"; then
    message "/etc/hosts has no managed entry to remove."
    exit 0
  fi

  require_root
  tmp_file="$(mktemp)"
  write_hosts_without_block "${tmp_file}"
  cp "${tmp_file}" "${hosts_file}"
  rm -f "${tmp_file}"
  message "/etc/hosts cleaned for managed entry."
fi
