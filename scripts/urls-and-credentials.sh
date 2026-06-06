#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: urls-and-credentials.sh [options]

Shows installed service URLs and deployed credentials for the current cluster.
Run it from clusters/<cluster>.

Options:
      --hide-secrets  Show URLs and usernames, but do not print passwords.
      --markdown      Render output as Markdown.
  -h, --help          Show this help message.
USAGE
}

show_secrets=true
output_format="console"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hide-secrets)
      show_secrets=false
      shift
      ;;
    --markdown)
      output_format="markdown"
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
markdown_section_count=0

emit_line() {
  local value="$1"

  if [[ "${output_format}" == "markdown" ]]; then
    printf '%s\n' "${value}"
  else
    message "${value}"
  fi
}

markdown_inline_code() {
  local value="$1"
  value="${value//\`/\\\`}"
  printf '`%s`' "${value}"
}

markdown_link() {
  local text="$1"
  local url="$2"

  text="${text//\\/\\\\}"
  text="${text//[/\\[}"
  text="${text//]/\\]}"
  url="${url// /%20}"
  url="${url//(/%28}"
  url="${url//)/%29}"
  printf '[%s](%s)' "${text}" "${url}"
}

if [[ "${output_format}" == "markdown" ]]; then
  printf '# Cluster URLs and Credentials\n\n'
  printf -- '- Cluster: `%s`\n' "${cluster_name}"
fi

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

output_json() {
  local workspace="$1"
  local output_name="$2"
  local output

  if ! workspace_has_state "${workspace}"; then
    return 0
  fi

  if output="$(tofu -chdir="${workspace}" output -json "${output_name}" 2>&1)"; then
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

  if [[ "${output_format}" == "markdown" ]]; then
    if (( markdown_section_count > 0 )); then
      printf '\n'
    fi
    printf '## %s\n\n' "${name}"
    markdown_section_count=$((markdown_section_count + 1))
  else
    message "${SERVICE_FMT_START}${name}${SERVICE_FMT_END}"
  fi
  printed_any=true
}

print_url_bullet() {
  local label="$1"
  local value="$2"

  if has_value "${value}"; then
    if [[ "${output_format}" == "markdown" ]]; then
      emit_line "- ${label}: $(markdown_link "${value}" "${value}")"
    else
      message "  - ${label}: ${URL_FMT_START}${value}${URL_FMT_END}"
    fi
    printed_any=true
  fi
}

print_data_bullet() {
  local label="$1"
  local value="$2"

  if has_value "${value}"; then
    if [[ "${output_format}" == "markdown" ]]; then
      emit_line "- ${label}: $(markdown_inline_code "${value}")"
    else
      message "  - ${label}: ${DATA_FMT_START}${value}${DATA_FMT_END}"
    fi
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
    if [[ "${output_format}" == "markdown" ]]; then
      emit_line "- ${label}: $(markdown_inline_code "<hidden>")"
    else
      message "  - ${label}: ${DATA_FMT_START}<hidden>${DATA_FMT_END}"
    fi
    printed_any=true
  fi
}

print_json_array_bullet() {
  local label="$1"
  local json="$2"
  local first_value
  local value

  if ! has_value "${json}" || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  first_value="$(jq -r 'if type == "array" and length > 0 then .[0] else "" end' <<< "${json}")"
  if ! has_value "${first_value}"; then
    return 0
  fi

  if [[ "${output_format}" == "markdown" ]]; then
    emit_line "- ${label}:"
  else
    message "  - ${label}:"
  fi
  printed_any=true
  while IFS= read -r value; do
    if has_value "${value}"; then
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "  - $(markdown_link "${value}" "${value}")"
      else
        message "    - ${URL_FMT_START}${value}${URL_FMT_END}"
      fi
    fi
  done < <(jq -r '.[]' <<< "${json}")
}

message_keycloak_realm_console_line() {
  local line="$1"
  local url

  case "${line}" in
    "  - "*)
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "  - ${line#"  - "}"
      else
        message "      - ${line#"  - "}"
      fi
      printed_any=true
      ;;
    "    Admin console: "*)
      url="${line#"    Admin console: "}"
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "    - Admin console: $(markdown_link "${url}" "${url}")"
      else
        message "        Admin console: ${URL_FMT_START}${url}${URL_FMT_END}"
      fi
      printed_any=true
      ;;
    "    Account URL:   "*)
      url="${line#"    Account URL:   "}"
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "    - Account URL: $(markdown_link "${url}" "${url}")"
      else
        message "        Account URL:   ${URL_FMT_START}${url}${URL_FMT_END}"
      fi
      printed_any=true
      ;;
    "    LDAP:          "*)
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "    - LDAP: ${line#"    LDAP:          "}"
      else
        message "        LDAP:          ${line#"    LDAP:          "}"
      fi
      printed_any=true
      ;;
    *)
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "  - ${line}"
      else
        message "    ${line}"
      fi
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
    if [[ "${output_format}" == "markdown" ]]; then
      emit_line "- Configured realms:"
    else
      message "  - Configured realms:"
    fi
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

print_redpanda_console() {
  local redpanda_console_url
  local kafka_listener_bootstrap
  local listener_name
  local listener_protocol
  local listener_scope
  local listener_bootstrap
  local schema_registry_service_url
  local redpanda_admin_service_url
  local redpanda_http_proxy_service_url

  redpanda_console_url="$(output_raw "${cluster_kafka_workspace}" redpanda_console_url)"
  if ! has_value "${redpanda_console_url}"; then
    return 0
  fi

  print_service "Redpanda Console"
  print_url_bullet "URL" "${redpanda_console_url}"

  kafka_listener_bootstrap="$(output_json "${cluster_kafka_workspace}" kafka_listener_bootstrap)"
  if has_value "${kafka_listener_bootstrap}" && command -v jq >/dev/null 2>&1; then
    if [[ "$(jq -r 'if type == "object" then length else 0 end' <<< "${kafka_listener_bootstrap}")" -gt 0 ]]; then
      if [[ "${output_format}" == "markdown" ]]; then
        emit_line "- Kafka bootstrap:"
      else
        message "  - Kafka bootstrap:"
      fi
      printed_any=true
    fi
    while IFS=$'\t' read -r listener_name listener_protocol listener_scope listener_bootstrap; do
      if has_value "${listener_name}" && has_value "${listener_bootstrap}"; then
        if [[ "${output_format}" == "markdown" ]]; then
          emit_line "  - ${listener_name} (${listener_protocol}, ${listener_scope}): $(markdown_inline_code "${listener_bootstrap}")"
        else
          message "    - ${listener_name} (${listener_protocol}, ${listener_scope}): ${DATA_FMT_START}${listener_bootstrap}${DATA_FMT_END}"
        fi
        printed_any=true
      fi
    done < <(jq -r 'to_entries[] | [.key, (.value.protocol // ""), (.value.scope // ""), (.value.bootstrap_server // "")] | @tsv' <<< "${kafka_listener_bootstrap}")
  fi

  schema_registry_service_url="$(output_raw "${cluster_kafka_workspace}" schema_registry_service_url)"
  print_url_bullet "Schema Registry URL" "${schema_registry_service_url}"
  redpanda_admin_service_url="$(output_raw "${cluster_kafka_workspace}" redpanda_admin_service_url)"
  print_url_bullet "Redpanda Admin API URL" "${redpanda_admin_service_url}"
  redpanda_http_proxy_service_url="$(output_raw "${cluster_kafka_workspace}" redpanda_http_proxy_service_url)"
  print_url_bullet "Redpanda HTTP Proxy URL" "${redpanda_http_proxy_service_url}"
}

print_s3_storage() {
  local garage_s3_endpoint_url
  local garage_internal_s3_endpoint_url
  local garage_console_url
  local garage_s3_region
  local garage_admin_token

  garage_s3_endpoint_url="$(output_raw "${cluster_s3_storage_workspace}" garage_s3_endpoint_url)"
  if ! has_value "${garage_s3_endpoint_url}"; then
    return 0
  fi

  print_service "S3 Storage"
  print_url_bullet "Endpoint URL" "${garage_s3_endpoint_url}"
  garage_internal_s3_endpoint_url="$(output_raw "${cluster_s3_storage_workspace}" garage_internal_s3_endpoint_url)"
  garage_console_url="$(output_raw "${cluster_s3_storage_workspace}" garage_console_url)"
  garage_s3_region="$(output_raw "${cluster_s3_storage_workspace}" garage_s3_region)"
  garage_admin_token="$(output_raw "${cluster_s3_storage_workspace}" garage_admin_token)"
  print_url_bullet "Internal endpoint URL" "${garage_internal_s3_endpoint_url}"
  print_url_bullet "Console URL" "${garage_console_url}"
  print_data_bullet "Region" "${garage_s3_region}"
  print_secret_bullet "Garage admin token" "${garage_admin_token}"
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
print_s3_storage
print_redpanda_console
print_rook_dashboard

if [[ "${printed_any}" != "true" ]]; then
  emit_line "No installed service URLs or deployed credentials found for cluster ${cluster_name}."
fi
