#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: extract-credentials-from-state.sh [--cluster <name>] [--overwrite] [--quiet]

Extracts service credentials from local out/*/terraform.tfstate files into
clusters/<cluster>/secrets/credentials.json. Existing values are preserved
unless --overwrite is passed. Secret values are never printed.

Run it from clusters/<cluster>.
USAGE
}

requested_cluster=""
overwrite=false
quiet=false

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
    --overwrite)
      overwrite=true
      shift
      ;;
    --quiet)
      quiet=true
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

setup_cluster_context "${script_dir}" "${requested_cluster}"
require_cmd jq

updated_count=0

ensure_credentials_file() {
  local legacy_credentials_path="${cluster_dir}/credentials.json"

  mkdir -p "${cluster_secrets_dir}"

  if [[ -f "${cluster_credentials_path}" ]]; then
    chmod 600 "${cluster_credentials_path}"
    return 0
  fi

  if [[ -f "${legacy_credentials_path}" ]]; then
    mv "${legacy_credentials_path}" "${cluster_credentials_path}"
    chmod 600 "${cluster_credentials_path}"
    return 0
  fi

  cat > "${cluster_credentials_path}" <<'JSON'
{
  "identity": {
    "keycloak_admin_password": "",
    "postgres_password": "",
    "oidc_client_secrets": {}
  },
  "monitoring": {
    "grafana_admin_password": "",
    "grafana_postgres_password": "",
    "prometheus_api_basic_auth_password": "",
    "prometheus_api_basic_auth_hash": "",
    "prometheus_oauth_cookie_secret": ""
  },
  "platform": {
    "portainer_admin_password": "",
    "rancher_bootstrap_password": ""
  },
  "s3_storage": {
    "garage_rpc_secret": "",
    "garage_admin_token": "",
    "garage_metrics_token": "",
    "garage_console_oauth_cookie_secret": ""
  },
  "kafka": {
    "redpanda_console_oauth_cookie_secret": ""
  }
}
JSON
  chmod 600 "${cluster_credentials_path}"
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

state_resource_attr() {
  local state_path="$1"
  local resource_type="$2"
  local resource_name="$3"
  local attr_name="$4"

  if [[ ! -r "${state_path}" ]]; then
    return 0
  fi

  jq -r \
    --arg type "${resource_type}" \
    --arg name "${resource_name}" \
    --arg attr "${attr_name}" \
    '.resources[]? | select(.type == $type and .name == $name) | .instances[0].attributes[$attr] // empty' \
    "${state_path}" 2>/dev/null || true
}

state_resource_for_each_attrs() {
  local state_path="$1"
  local resource_type="$2"
  local resource_name="$3"
  local attr_name="$4"

  if [[ ! -r "${state_path}" ]]; then
    return 0
  fi

  jq -r \
    --arg type "${resource_type}" \
    --arg name "${resource_name}" \
    --arg attr "${attr_name}" \
    '.resources[]? | select(.type == $type and .name == $name) | .instances[]? | select(.index_key != null) | [.index_key, (.attributes[$attr] // empty)] | @tsv' \
    "${state_path}" 2>/dev/null || true
}

state_oidc_client_secret_outputs() {
  local state_path="$1"

  if [[ ! -r "${state_path}" ]]; then
    return 0
  fi

  jq -r '
    .outputs.keycloak_realm_definitions.value[]? as $realm |
    $realm.oidc_clients[]? |
    select(.access_type == "confidential" and ((.client_secret // "") != "")) |
    [($realm.name + "/" + .client_id), .client_secret] |
    @tsv
  ' "${state_path}" 2>/dev/null || true
}

seed_json_string() {
  local jq_path="$1"
  local value="$2"
  local current

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    return 0
  fi

  current="$(json_get_string "${jq_path}")"
  if [[ "${overwrite}" != "true" && -n "${current}" ]]; then
    return 0
  fi

  if [[ "${current}" == "${value}" ]]; then
    return 0
  fi

  json_set_string "${jq_path}" "${value}"
  updated_count=$((updated_count + 1))
}

extract_identity_credentials() {
  local state_path="${cluster_identity_workspace}/terraform.tfstate"
  local key
  local value

  seed_json_string ".identity.postgres_password" "$(state_resource_attr "${state_path}" random_password postgres_password result)"
  seed_json_string ".identity.keycloak_admin_password" "$(state_resource_attr "${state_path}" random_password keycloak_admin_password result)"

  while IFS=$'\t' read -r key value; do
    seed_json_string ".identity.oidc_client_secrets[\"${key}\"]" "${value}"
  done < <(state_resource_for_each_attrs "${state_path}" random_password oidc_client_secret result)

  while IFS=$'\t' read -r key value; do
    seed_json_string ".identity.oidc_client_secrets[\"${key}\"]" "${value}"
  done < <(state_oidc_client_secret_outputs "${state_path}")
}

extract_monitoring_credentials() {
  local state_path="${cluster_monitoring_workspace}/terraform.tfstate"

  seed_json_string ".monitoring.grafana_admin_password" "$(state_resource_attr "${state_path}" random_password grafana_admin result)"
  seed_json_string ".monitoring.grafana_postgres_password" "$(state_resource_attr "${state_path}" random_password grafana_postgres result)"
  seed_json_string ".monitoring.prometheus_api_basic_auth_password" "$(state_resource_attr "${state_path}" random_password prometheus_api_basic_auth result)"
  seed_json_string ".monitoring.prometheus_api_basic_auth_hash" "$(state_resource_attr "${state_path}" random_password prometheus_api_basic_auth bcrypt_hash)"
  seed_json_string ".monitoring.prometheus_oauth_cookie_secret" "$(state_resource_attr "${state_path}" random_password prometheus_oauth_cookie_secret result)"
}

extract_platform_credentials() {
  local state_path="${cluster_platform_workspace}/terraform.tfstate"

  seed_json_string ".platform.portainer_admin_password" "$(state_resource_attr "${state_path}" random_password portainer_admin result)"
  seed_json_string ".platform.rancher_bootstrap_password" "$(state_resource_attr "${state_path}" random_password rancher_bootstrap result)"
}

extract_s3_storage_credentials() {
  local state_path="${cluster_s3_storage_workspace}/terraform.tfstate"

  seed_json_string ".s3_storage.garage_rpc_secret" "$(state_resource_attr "${state_path}" random_id garage_rpc_secret hex)"
  seed_json_string ".s3_storage.garage_admin_token" "$(state_resource_attr "${state_path}" random_password garage_admin_token result)"
  seed_json_string ".s3_storage.garage_metrics_token" "$(state_resource_attr "${state_path}" random_password garage_metrics_token result)"
  seed_json_string ".s3_storage.garage_console_oauth_cookie_secret" "$(state_resource_attr "${state_path}" random_password garage_console_oauth_cookie_secret result)"
}

extract_kafka_credentials() {
  local state_path="${cluster_kafka_workspace}/terraform.tfstate"

  seed_json_string ".kafka.redpanda_console_oauth_cookie_secret" "$(state_resource_attr "${state_path}" random_password redpanda_console_oauth_cookie_secret result)"
}

ensure_credentials_file
extract_identity_credentials
extract_monitoring_credentials
extract_platform_credentials
extract_s3_storage_credentials
extract_kafka_credentials

if [[ "${quiet}" != "true" ]]; then
  message "Extracted ${updated_count} credential value(s) into ${cluster_credentials_path}."
fi
