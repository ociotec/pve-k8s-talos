#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: ensure-credentials.sh [--cluster <name>]

Extracts reusable credentials from local out/* state when present, generates
missing cluster credentials in secrets/credentials.json, and creates an internal
root CA under certs/ when k8s_net_constants.tf requests one.
Run it from clusters/<cluster>.
USAGE
}

requested_cluster=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      if [[ $# -lt 2 || -z "$2" ]]; then
        error "--cluster requires a value."
        exit 1
      fi
      requested_cluster="$2"
      shift 2
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

setup_cluster_context "${script_dir}" "${requested_cluster}"
require_cmd jq
require_cmd openssl

tf_string_value() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" -F'"' '$0 ~ "^[[:space:]]*" name "[[:space:]]*=" { print $2; exit }' "${file}" 2>/dev/null || true
}

tf_number_value() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" '$0 ~ "^[[:space:]]*" name "[[:space:]]*=" { gsub(/#.*/, ""); gsub(/[^0-9]/, "", $0); print $0; exit }' "${file}" 2>/dev/null || true
}

resolve_cluster_path() {
  local raw_path="$1"

  case "${raw_path}" in
    "")
      printf ""
      ;;
    /*)
      printf "%s" "${raw_path}"
      ;;
    *)
      printf "%s/%s" "${cluster_dir}" "${raw_path#./}"
      ;;
  esac
}

random_alnum() {
  local length="$1"
  local value=""

  while [[ "${#value}" -lt "${length}" ]]; do
    value+="$(
      openssl rand -base64 96 |
        tr -dc 'A-Za-z0-9' |
        head -c "${length}" || true
    )"
  done
  printf "%s" "${value:0:${length}}"
}

json_get_string() {
  local jq_path="$1"
  jq -r "${jq_path} // empty" "${cluster_credentials_path}"
}

json_set_string() {
  local jq_path="$1"
  local value="$2"
  local tmp

  tmp="$(mktemp)"
  jq --arg value "${value}" "${jq_path} = \$value" "${cluster_credentials_path}" > "${tmp}"
  mv "${tmp}" "${cluster_credentials_path}"
  chmod 600 "${cluster_credentials_path}"
}

ensure_json_string() {
  local jq_path="$1"
  local length="$2"
  local value

  value="$(json_get_string "${jq_path}")"
  if [[ -n "${value}" ]]; then
    return 0
  fi

  json_set_string "${jq_path}" "$(random_alnum "${length}")"
}

ensure_json_hex() {
  local jq_path="$1"
  local bytes="$2"
  local value

  value="$(json_get_string "${jq_path}")"
  if [[ -n "${value}" ]]; then
    return 0
  fi

  json_set_string "${jq_path}" "$(openssl rand -hex "${bytes}")"
}

ensure_prometheus_api_basic_auth_hash() {
  local password
  local hash

  hash="$(json_get_string ".monitoring.prometheus_api_basic_auth_hash")"
  if [[ -n "${hash}" ]]; then
    return 0
  fi

  password="$(json_get_string ".monitoring.prometheus_api_basic_auth_password")"
  if [[ -z "${password}" ]]; then
    return 0
  fi

  json_set_string ".monitoring.prometheus_api_basic_auth_hash" "$(openssl passwd -apr1 "${password}")"
}

ensure_oidc_client_secret() {
  local realm="$1"
  local client_id="$2"

  if [[ -z "${realm}" || -z "${client_id}" ]]; then
    return 0
  fi

  ensure_json_string ".identity.oidc_client_secrets[\"${realm}/${client_id}\"]" 32
}

ensure_service_credentials() {
  local length

  if [[ -r "${cluster_identity_constants_path}" ]]; then
    length="$(tf_number_value "${cluster_identity_constants_path}" keycloak_admin_password_length)"
    ensure_json_string ".identity.keycloak_admin_password" "${length:-24}"
    length="$(tf_number_value "${cluster_identity_constants_path}" postgres_password_length)"
    ensure_json_string ".identity.postgres_password" "${length:-24}"
  fi

  if [[ -r "${cluster_platform_constants_path}" ]]; then
    length="$(tf_number_value "${cluster_platform_constants_path}" portainer_admin_password_length)"
    ensure_json_string ".platform.portainer_admin_password" "${length:-24}"
    length="$(tf_number_value "${cluster_platform_constants_path}" rancher_bootstrap_password_length)"
    ensure_json_string ".platform.rancher_bootstrap_password" "${length:-24}"
    ensure_oidc_client_secret "$(tf_string_value "${cluster_platform_constants_path}" rancher_auth_keycloak_realm)" "rancher"
    ensure_oidc_client_secret "$(tf_string_value "${cluster_platform_constants_path}" portainer_auth_keycloak_realm)" "portainer"
  fi

  if [[ -r "${cluster_monitoring_constants_path}" ]]; then
    length="$(tf_number_value "${cluster_monitoring_constants_path}" grafana_admin_password_length)"
    ensure_json_string ".monitoring.grafana_admin_password" "${length:-24}"
    length="$(tf_number_value "${cluster_monitoring_constants_path}" grafana_postgres_password_length)"
    ensure_json_string ".monitoring.grafana_postgres_password" "${length:-24}"
    length="$(tf_number_value "${cluster_monitoring_constants_path}" prometheus_api_basic_auth_password_length)"
    ensure_json_string ".monitoring.prometheus_api_basic_auth_password" "${length:-32}"
    ensure_prometheus_api_basic_auth_hash
    ensure_json_string ".monitoring.prometheus_oauth_cookie_secret" 32
    ensure_oidc_client_secret "$(tf_string_value "${cluster_monitoring_constants_path}" grafana_auth_keycloak_realm)" "grafana"
    ensure_oidc_client_secret "$(tf_string_value "${cluster_monitoring_constants_path}" prometheus_auth_keycloak_realm)" "prometheus"
  fi

  if [[ -r "${cluster_s3_storage_constants_path}" ]]; then
    ensure_json_hex ".s3_storage.garage_rpc_secret" 32
    ensure_json_string ".s3_storage.garage_admin_token" 48
    ensure_json_string ".s3_storage.garage_metrics_token" 48
    ensure_json_string ".s3_storage.garage_console_oauth_cookie_secret" 32
    ensure_oidc_client_secret "$(tf_string_value "${cluster_s3_storage_constants_path}" garage_console_auth_keycloak_realm)" "garage-console"
  fi

  if [[ -r "${cluster_kafka_constants_path}" ]]; then
    ensure_json_string ".kafka.redpanda_console_oauth_cookie_secret" 32
    ensure_oidc_client_secret "$(tf_string_value "${cluster_kafka_constants_path}" redpanda_console_auth_keycloak_realm)" "redpanda-console"
  fi
}

ensure_root_ca() {
  local tls_source
  local root_ca_crt_raw
  local root_ca_key_raw
  local root_ca_crt_path
  local root_ca_key_path
  local common_name
  local organization
  local validity_hours
  local validity_days

  if [[ ! -r "${cluster_k8s_net_constants_path}" ]]; then
    return 0
  fi

  tls_source="$(tf_string_value "${cluster_k8s_net_constants_path}" tls_source)"
  if [[ "${tls_source:-ca_issuer}" != "ca_issuer" ]]; then
    return 0
  fi

  root_ca_crt_raw="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_crt)"
  root_ca_key_raw="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_key)"
  if [[ -z "${root_ca_crt_raw}" && -z "${root_ca_key_raw}" ]]; then
    return 0
  fi
  if [[ -z "${root_ca_crt_raw}" || -z "${root_ca_key_raw}" ]]; then
    error "root_ca_crt and root_ca_key must both be set to generate or reuse an internal root CA." >&2
    exit 1
  fi

  root_ca_crt_path="$(resolve_cluster_path "${root_ca_crt_raw}")"
  root_ca_key_path="$(resolve_cluster_path "${root_ca_key_raw}")"
  if [[ -s "${root_ca_crt_path}" && -s "${root_ca_key_path}" ]]; then
    return 0
  fi
  if [[ -e "${root_ca_crt_path}" || -e "${root_ca_key_path}" ]]; then
    error "Refusing to overwrite partial root CA files: ${root_ca_crt_path}, ${root_ca_key_path}" >&2
    exit 1
  fi

  common_name="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_common_name)"
  organization="$(tf_string_value "${cluster_k8s_net_constants_path}" root_ca_organization)"
  validity_hours="$(tf_number_value "${cluster_k8s_net_constants_path}" root_ca_validity_hours)"
  common_name="${common_name:-${cluster_name}}"
  organization="${organization:-Generated local CA}"
  validity_days=$(( (${validity_hours:-876000} + 23) / 24 ))

  mkdir -p "$(dirname "${root_ca_crt_path}")" "$(dirname "${root_ca_key_path}")"
  message "Generating internal root CA at ${root_ca_crt_path} and ${root_ca_key_path}..."
  openssl req \
    -x509 \
    -newkey rsa:4096 \
    -sha256 \
    -days "${validity_days}" \
    -nodes \
    -subj "/CN=${common_name}/O=${organization}" \
    -keyout "${root_ca_key_path}" \
    -out "${root_ca_crt_path}" \
    1>/dev/null 2>&1
  chmod 600 "${root_ca_key_path}"
  chmod 644 "${root_ca_crt_path}"
}

"${script_dir}/extract-credentials-from-state.sh" --cluster "${cluster_name}" --quiet
ensure_service_credentials
ensure_root_ca

message "Credentials are present at ${cluster_credentials_path}."
