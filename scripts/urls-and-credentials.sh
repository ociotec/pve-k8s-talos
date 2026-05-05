#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: urls-and-credentials.sh [options]

Shows installed service URLs and generated credentials for the current cluster.
Run it from clusters/<cluster>.

Options:
      --hide-secrets  Show URLs and usernames, but do not print passwords.
  -h, --help          Show this help message.
USAGE
}

show_secrets=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hide-secrets)
      show_secrets=false
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

setup_cluster_context "${script_dir}" ""
require_cmd tofu

URL_FMT_START="\033[1m\033[3m\033[4m"
URL_FMT_END="\033[24m\033[23m\033[22m"
SERVICE_FMT_START="\033[1m"
SERVICE_FMT_END="\033[22m"
DATA_FMT_START="\033[1m\033[3m"
DATA_FMT_END="\033[23m\033[22m"

printed_any=false

workspace_has_state() {
  local workspace="$1"
  [[ -f "${workspace}/terraform.tfstate" || -f "${workspace}/terraform.tfstate.backup" ]]
}

output_raw() {
  local workspace="$1"
  local output_name="$2"
  local output

  if ! workspace_has_state "${workspace}"; then
    return 0
  fi

  if output="$(tofu -chdir="${workspace}" output -raw "${output_name}" 2>&1)"; then
    printf "%s" "${output}"
    return 0
  fi

  case "${output}" in
    *"No outputs found"*|*"output variable requested could not be found"*|*"No output named"*|*'Output "'*'" not found'*)
      return 0
      ;;
    *)
      error "Failed to read OpenTofu output ${output_name} in ${workspace}. Output:" >&2
      printf "%s\n" "${output}" >&2
      return 1
      ;;
  esac
}

has_value() {
  local value="$1"
  [[ -n "${value}" && "${value}" != "null" ]]
}

print_service() {
  local name="$1"

  message "${SERVICE_FMT_START}${name}${SERVICE_FMT_END}"
  printed_any=true
}

print_url_bullet() {
  local label="$1"
  local value="$2"

  if has_value "${value}"; then
    message "  - ${label}: ${URL_FMT_START}${value}${URL_FMT_END}"
    printed_any=true
  fi
}

print_data_bullet() {
  local label="$1"
  local value="$2"

  if has_value "${value}"; then
    message "  - ${label}: ${DATA_FMT_START}${value}${DATA_FMT_END}"
    printed_any=true
  fi
}

print_secret_bullet() {
  local label="$1"
  local value="$2"

  if ! has_value "${value}"; then
    return 0
  fi

  if [[ "${show_secrets}" == "true" ]]; then
    print_data_bullet "${label}" "${value}"
  else
    message "  - ${label}: ${DATA_FMT_START}<hidden>${DATA_FMT_END}"
    printed_any=true
  fi
}

message_keycloak_realm_console_line() {
  local line="$1"
  local url

  case "${line}" in
    "  - "*)
      message "      - ${line#"  - "}"
      printed_any=true
      ;;
    "    Admin console: "*)
      url="${line#"    Admin console: "}"
      message "        Admin console: ${URL_FMT_START}${url}${URL_FMT_END}"
      printed_any=true
      ;;
    "    Account URL:   "*)
      url="${line#"    Account URL:   "}"
      message "        Account URL:   ${URL_FMT_START}${url}${URL_FMT_END}"
      printed_any=true
      ;;
    "    LDAP:          "*)
      message "        LDAP:          ${line#"    LDAP:          "}"
      printed_any=true
      ;;
    *)
      message "    ${line}"
      printed_any=true
      ;;
  esac
}

first_worker_ip() {
  local resources_file="${1:-${cluster_resources_path}}"
  local vms_file="${2:-${cluster_vms_path}}"
  local worker_types

  if [[ ! -r "${resources_file}" || ! -r "${vms_file}" ]]; then
    return 0
  fi

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

print_keycloak() {
  local keycloak_url
  local keycloak_admin_user
  local keycloak_admin_password
  local keycloak_realm_console_summary
  local keycloak_realm_console_line

  keycloak_url="$(output_raw "${cluster_identity_workspace}" keycloak_url)"
  if ! has_value "${keycloak_url}"; then
    return 0
  fi

  print_service "Keycloak"
  print_url_bullet "URL" "${keycloak_url}"
  keycloak_admin_user="$(output_raw "${cluster_identity_workspace}" keycloak_admin_user)"
  keycloak_admin_password="$(output_raw "${cluster_identity_workspace}" keycloak_admin_password)"
  print_data_bullet "Admin user" "${keycloak_admin_user}"
  print_secret_bullet "Admin password" "${keycloak_admin_password}"

  keycloak_realm_console_summary="$(output_raw "${cluster_identity_workspace}" keycloak_realm_console_summary)"
  if [[ -n "${keycloak_realm_console_summary}" ]]; then
    message "  - Configured realms:"
    while IFS= read -r keycloak_realm_console_line; do
      message_keycloak_realm_console_line "${keycloak_realm_console_line}"
    done <<< "${keycloak_realm_console_summary}"
  fi
}

print_grafana() {
  local grafana_url
  local grafana_user
  local grafana_password

  grafana_url="$(output_raw "${cluster_monitoring_workspace}" grafana_url)"
  if ! has_value "${grafana_url}"; then
    return 0
  fi

  print_service "Grafana"
  print_url_bullet "URL" "${grafana_url}"
  grafana_user="$(output_raw "${cluster_monitoring_workspace}" grafana_admin_user)"
  grafana_password="$(output_raw "${cluster_monitoring_workspace}" grafana_admin_password)"
  print_data_bullet "Admin user" "${grafana_user}"
  print_secret_bullet "Admin password" "${grafana_password}"
}

print_prometheus() {
  local prometheus_url
  local prometheus_api_url
  local prometheus_api_user
  local prometheus_api_password

  prometheus_url="$(output_raw "${cluster_monitoring_workspace}" prometheus_url)"
  if ! has_value "${prometheus_url}"; then
    return 0
  fi

  print_service "Prometheus"
  print_url_bullet "URL" "${prometheus_url}"
  prometheus_api_url="$(output_raw "${cluster_monitoring_workspace}" prometheus_api_url)"
  prometheus_api_user="$(output_raw "${cluster_monitoring_workspace}" prometheus_api_basic_auth_user)"
  prometheus_api_password="$(output_raw "${cluster_monitoring_workspace}" prometheus_api_basic_auth_password)"
  print_url_bullet "API URL" "${prometheus_api_url}"
  print_data_bullet "API user" "${prometheus_api_user}"
  print_secret_bullet "API password" "${prometheus_api_password}"
}

print_portainer() {
  local portainer_url
  local portainer_admin_password

  portainer_url="$(output_raw "${cluster_platform_workspace}" portainer_url)"
  if ! has_value "${portainer_url}"; then
    return 0
  fi

  print_service "Portainer"
  print_url_bullet "URL" "${portainer_url}"
  print_data_bullet "Admin user" "admin"
  portainer_admin_password="$(output_raw "${cluster_platform_workspace}" portainer_admin_password)"
  print_secret_bullet "Admin password" "${portainer_admin_password}"
}

print_rancher() {
  local rancher_enabled
  local rancher_url
  local rancher_bootstrap_password

  rancher_enabled="$(output_raw "${cluster_platform_workspace}" rancher_enabled)"
  rancher_url="$(output_raw "${cluster_platform_workspace}" rancher_url)"
  if [[ "${rancher_enabled}" != "true" ]] || ! has_value "${rancher_url}"; then
    return 0
  fi

  print_service "Rancher"
  print_url_bullet "URL" "${rancher_url}"
  print_data_bullet "Admin user" "admin"
  rancher_bootstrap_password="$(output_raw "${cluster_platform_workspace}" rancher_bootstrap_password)"
  print_secret_bullet "Admin password" "${rancher_bootstrap_password}"
}

print_rook_dashboard() {
  local rook_dashboard_url
  local dashboard_nodeport
  local worker_ip
  local dashboard_password_encoded
  local dashboard_password

  rook_dashboard_url="$(output_raw "${cluster_rook_03_workspace}" rook_ceph_dashboard_url)"
  if ! has_value "${rook_dashboard_url}"; then
    return 0
  fi

  print_service "Rook Ceph Dashboard"
  print_url_bullet "URL" "${rook_dashboard_url}"

  if [[ -r "${cluster_kubeconfig_path}" ]] && command -v kubectl >/dev/null 2>&1; then
    dashboard_nodeport="$(kubectl --kubeconfig "${cluster_kubeconfig_path}" -n rook-ceph get svc rook-ceph-mgr-dashboard-external-https -o jsonpath='{.spec.ports[?(@.name=="dashboard")].nodePort}' 2>/dev/null || true)"
    worker_ip="$(first_worker_ip)"
    if has_value "${dashboard_nodeport}" && has_value "${worker_ip}"; then
      print_url_bullet "NodePort URL" "https://${worker_ip}:${dashboard_nodeport}/"
    fi

    dashboard_password_encoded="$(kubectl --kubeconfig "${cluster_kubeconfig_path}" -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' 2>/dev/null || true)"
    if has_value "${dashboard_password_encoded}" && command -v base64 >/dev/null 2>&1; then
      dashboard_password="$(printf "%s" "${dashboard_password_encoded}" | base64 --decode 2>/dev/null || true)"
      print_data_bullet "User" "admin"
      print_secret_bullet "Password" "${dashboard_password}"
    fi
  fi
}

print_keycloak
print_grafana
print_prometheus
print_portainer
print_rancher
print_rook_dashboard

if [[ "${printed_any}" != "true" ]]; then
  message "No installed service URLs or generated credentials found for cluster ${cluster_name}."
fi
