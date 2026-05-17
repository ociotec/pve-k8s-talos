#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[keycloak-api] missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "[keycloak-api] missing required environment variable: $1" >&2
    exit 1
  fi
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

api_path() {
  local path="$1"
  printf '%s/admin/%s' "${KEYCLOAK_URL%/}" "${path#/}"
}

token_url() {
  printf '%s/realms/master/protocol/openid-connect/token' "${KEYCLOAK_URL%/}"
}

client_credentials_login() {
  ACCESS_TOKEN="$(
    curl -k -fsS \
      -X POST "$(token_url)" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=${KEYCLOAK_CONFIG_CLIENT_ID}" \
      --data-urlencode "client_secret=${KEYCLOAK_ADMIN_PASSWORD}" \
      --data-urlencode "grant_type=client_credentials" |
      jq -r '.access_token'
  )"

  [[ -n "${ACCESS_TOKEN}" && "${ACCESS_TOKEN}" != "null" ]]
}

password_login() {
  ACCESS_TOKEN="$(
    curl -k -fsS \
      -X POST "$(token_url)" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "username=${KEYCLOAK_ADMIN_USER}" \
      --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" |
      jq -r '.access_token'
  )"

  [[ -n "${ACCESS_TOKEN}" && "${ACCESS_TOKEN}" != "null" ]]
}

login() {
  if client_credentials_login 2>/dev/null; then
    return 0
  fi
  if password_login 2>/dev/null; then
    return 0
  fi
  echo "[keycloak-api] could not obtain admin access token" >&2
  return 1
}

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local status
  local output_file
  local attempt

  for attempt in 1 2; do
    output_file="$(mktemp)"
    local args=(-k -sS -o "${output_file}" -w "%{http_code}" -X "${method}" "$(api_path "${path}")" -H "Authorization: Bearer ${ACCESS_TOKEN}")

    if [[ -n "${body}" ]]; then
      args+=(-H "Content-Type: application/json" --data-binary @"${body}")
    fi

    status="$(curl "${args[@]}")"
    if [[ "${status}" == "401" && "${attempt}" -eq 1 ]]; then
      rm -f "${output_file}"
      login >/dev/null 2>&1 || return 1
      continue
    fi
    if [[ "${status}" -lt 200 || "${status}" -gt 299 ]]; then
      echo "[keycloak-api] ${method} ${path} failed with HTTP ${status}" >&2
      cat "${output_file}" >&2 || true
      rm -f "${output_file}"
      return 1
    fi
    cat "${output_file}"
    rm -f "${output_file}"
    return 0
  done
}

api_allow_404() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local status
  local output_file
  local attempt

  for attempt in 1 2; do
    output_file="$(mktemp)"
    local args=(-k -sS -o "${output_file}" -w "%{http_code}" -X "${method}" "$(api_path "${path}")" -H "Authorization: Bearer ${ACCESS_TOKEN}")

    if [[ -n "${body}" ]]; then
      args+=(-H "Content-Type: application/json" --data-binary @"${body}")
    fi

    status="$(curl "${args[@]}")"
    if [[ "${status}" == "401" && "${attempt}" -eq 1 ]]; then
      rm -f "${output_file}"
      login >/dev/null 2>&1 || return 1
      continue
    fi
    if [[ "${status}" == "404" ]]; then
      rm -f "${output_file}"
      return 44
    fi
    if [[ "${status}" -lt 200 || "${status}" -gt 299 ]]; then
      cat "${output_file}" >&2 || true
      rm -f "${output_file}"
      return 1
    fi
    cat "${output_file}"
    rm -f "${output_file}"
    return 0
  done
}

json_file() {
  local file="$1"
  shift
  jq -n "$@" > "${file}"
}

realm_exists() {
  api_allow_404 GET "realms/$(urlencode "$1")" >/dev/null
}

realm_uuid() {
  api GET "realms/$(urlencode "$1")" | jq -r '.id // empty'
}

client_uuid() {
  local realm="$1"
  local client_id="$2"
  api GET "realms/$(urlencode "${realm}")/clients?clientId=$(urlencode "${client_id}")" |
    jq -r --arg client_id "${client_id}" '.[] | select(.clientId == $client_id) | .id' |
    head -n1
}

user_id() {
  local realm="$1"
  local username="$2"
  api GET "realms/$(urlencode "${realm}")/users?username=$(urlencode "${username}")" |
    jq -r --arg username "${username}" '.[] | select(.username == $username) | .id' |
    head -n1
}

service_account_user_id() {
  local realm="$1"
  local client_identifier="$2"
  local client_id_value
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  api GET "realms/$(urlencode "${realm}")/clients/${client_id_value}/service-account-user" |
    jq -r '.id // empty'
}

group_id() {
  local realm="$1"
  local group_name="$2"
  api GET "realms/$(urlencode "${realm}")/groups?exact=true&search=$(urlencode "${group_name}")" |
    jq -r --arg group_name "${group_name}" '.[] | select(.name == $group_name) | .id' |
    head -n1
}

group_id_by_path() {
  local realm="$1"
  local group_path="${2#/}"
  api_allow_404 GET "realms/$(urlencode "${realm}")/group-by-path/$(urlencode "${group_path}")" |
    jq -r '.id // empty'
}

wait_for_group() {
  local realm="$1"
  local group_name="$2"
  local id=""
  local started_at
  started_at="$(date +%s)"

  while [[ -z "${id}" ]]; do
    id="$(group_id_by_path "${realm}" "/${group_name}" 2>/dev/null || true)"
    if [[ -z "${id}" ]]; then
      id="$(group_id "${realm}" "${group_name}")"
    fi
    if [[ -n "${id}" ]]; then
      printf '%s\n' "${id}"
      return 0
    fi
    if (( "$(date +%s)" - started_at > 120 )); then
      echo "[keycloak-api] timed out waiting for group ${realm}/${group_name}" >&2
      return 1
    fi
    sleep 2
  done
}

flow_id_by_alias() {
  local realm="$1"
  local alias="$2"
  api GET "realms/$(urlencode "${realm}")/authentication/flows" |
    jq -r --arg alias "${alias}" '.[] | select(.alias == $alias) | .id' |
    head -n1
}

execution_by_provider() {
  local realm="$1"
  local flow_alias="$2"
  local provider_id="$3"
  api GET "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${flow_alias}")/executions" |
    jq -r --arg provider_id "${provider_id}" '.[] | select(.providerId == $provider_id) | .id' |
    head -n1
}

execution_by_display() {
  local realm="$1"
  local flow_alias="$2"
  local display_name="$3"
  api GET "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${flow_alias}")/executions" |
    jq -r --arg display_name "${display_name}" '.[] | select(.displayName == $display_name or .alias == $display_name) | .id' |
    head -n1
}

client_protocol_mapper_id() {
  local realm="$1"
  local client_id_value="$2"
  local mapper_name="$3"
  api GET "realms/$(urlencode "${realm}")/clients/${client_id_value}/protocol-mappers/models" |
    jq -r --arg mapper_name "${mapper_name}" '.[] | select(.name == $mapper_name) | .id' |
    head -n1
}

component_id() {
  local realm="$1"
  local parent_id="$2"
  local provider_type="$3"
  local component_name="$4"
  api GET "realms/$(urlencode "${realm}")/components?parent=$(urlencode "${parent_id}")&type=$(urlencode "${provider_type}")&name=$(urlencode "${component_name}")" |
    jq -r \
      --arg parent_id "${parent_id}" \
      --arg provider_type "${provider_type}" \
      --arg component_name "${component_name}" \
      '.[] | select(.parentId == $parent_id and .providerType == $provider_type and .name == $component_name) | .id' |
    head -n1
}

role_json() {
  local realm="$1"
  local client_id_value="$2"
  local role_name="$3"
  api GET "realms/$(urlencode "${realm}")/clients/${client_id_value}/roles/$(urlencode "${role_name}")"
}

realm_role_json() {
  local realm="$1"
  local role_name="$2"
  api GET "realms/$(urlencode "${realm}")/roles/$(urlencode "${role_name}")"
}

assign_user_realm_role() {
  local realm="$1"
  local user_id_value="$2"
  local role_name="$3"
  local role_payload
  role_payload="${TMPDIR}/user-realm-role-${realm}-${user_id_value}-${role_name}.json"
  realm_role_json "${realm}" "${role_name}" | jq '[.]' > "${role_payload}"
  api POST "realms/$(urlencode "${realm}")/users/${user_id_value}/role-mappings/realm" "${role_payload}" >/dev/null || true
}

assign_user_client_role() {
  local realm="$1"
  local user_id_value="$2"
  local client_identifier="$3"
  local role_name="$4"
  local client_id_value
  local role_payload
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  role_payload="${TMPDIR}/user-role-${realm}-${user_id_value}-${client_identifier}-${role_name}.json"
  role_json "${realm}" "${client_id_value}" "${role_name}" | jq '[.]' > "${role_payload}"
  api POST "realms/$(urlencode "${realm}")/users/${user_id_value}/role-mappings/clients/${client_id_value}" "${role_payload}" >/dev/null || true
}

assign_client_scope_client_role() {
  local realm="$1"
  local client_identifier="$2"
  local role_client_identifier="$3"
  local role_name="$4"
  local client_id_value
  local role_client_id
  local role_payload
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  role_client_id="$(client_uuid "${realm}" "${role_client_identifier}")"
  role_payload="${TMPDIR}/client-scope-${realm}-${client_identifier}-${role_client_identifier}-${role_name}.json"
  role_json "${realm}" "${role_client_id}" "${role_name}" | jq '[.]' > "${role_payload}"
  api POST "realms/$(urlencode "${realm}")/clients/${client_id_value}/scope-mappings/clients/${role_client_id}" "${role_payload}" >/dev/null || true
}

ensure_master_admin_user() {
  local user_id_value
  local payload
  user_id_value="$(user_id master "${KEYCLOAK_ADMIN_USER}")"

  if [[ -z "${user_id_value}" ]]; then
    echo "[keycloak-api] master: creating permanent admin user ${KEYCLOAK_ADMIN_USER}"
    payload="${TMPDIR}/master-admin-user.json"
    jq -n \
      --arg username "${KEYCLOAK_ADMIN_USER}" \
      --arg password "${KEYCLOAK_ADMIN_PASSWORD}" \
      '{
        username: $username,
        enabled: true,
        emailVerified: true,
        requiredActions: [],
        credentials: [{
          type: "password",
          temporary: false,
          value: $password
        }]
      }' > "${payload}"
    api POST "realms/master/users" "${payload}" >/dev/null
    user_id_value="$(user_id master "${KEYCLOAK_ADMIN_USER}")"
  else
    echo "[keycloak-api] master: permanent admin user ${KEYCLOAK_ADMIN_USER} exists"
  fi

  if [[ -z "${user_id_value}" ]]; then
    echo "[keycloak-api] could not resolve master admin user ${KEYCLOAK_ADMIN_USER}" >&2
    exit 1
  fi

  echo "[keycloak-api] master: setting permanent admin password"
  payload="${TMPDIR}/master-admin-password.json"
  jq -n --arg password "${KEYCLOAK_ADMIN_PASSWORD}" '{type: "password", temporary: false, value: $password}' > "${payload}"
  api PUT "realms/master/users/${user_id_value}/reset-password" "${payload}" >/dev/null
  echo "[keycloak-api] master: assigning admin role"
  assign_user_realm_role master "${user_id_value}" admin
}

configure_master_realm_settings() {
  local payload
  if [[ -z "${KEYCLOAK_MASTER_REALM_SETTINGS_JSON:-}" || "${KEYCLOAK_MASTER_REALM_SETTINGS_JSON}" == "null" ]]; then
    return 0
  fi

  echo "[keycloak-api] master: settings"
  payload="${TMPDIR}/master-realm-settings.json"
  jq -n --argjson settings "${KEYCLOAK_MASTER_REALM_SETTINGS_JSON}" '{
    realm: "master",
    enabled: true,
    eventsEnabled: ($settings.save_user_events // false),
    adminEventsEnabled: ($settings.save_admin_events // false),
    adminEventsDetailsEnabled: ($settings.save_admin_event_details // ($settings.save_admin_events // false))
  }' > "${payload}"
  api PUT "realms/master" "${payload}" >/dev/null
}

upsert_realm() {
  local realm_json="$1"
  local realm
  local payload
  realm="$(jq -r '.name' "${realm_json}")"
  payload="${TMPDIR}/realm-${realm}.json"

  jq '{
    realm: .name,
    enabled: true,
    eventsEnabled: .settings.save_user_events,
    adminEventsEnabled: .settings.save_admin_events,
    adminEventsDetailsEnabled: .settings.save_admin_events
  }' "${realm_json}" > "${payload}"

  if realm_exists "${realm}"; then
    api PUT "realms/$(urlencode "${realm}")" "${payload}" >/dev/null
  else
    api POST "realms" "${payload}" >/dev/null
  fi
}

upsert_client() {
  local realm="$1"
  local client_json="$2"
  local client_id_value
  local client_identifier
  local payload
  client_identifier="$(jq -r '.client_id' "${client_json}")"
  payload="${TMPDIR}/client-${realm}-${client_identifier}.json"

  jq '{
    clientId: .client_id,
    name: .name,
    description: .description,
    enabled: .enabled,
    protocol: "openid-connect",
    publicClient: (.access_type == "public"),
    bearerOnly: (.access_type == "bearer-only"),
    standardFlowEnabled: .standard_flow_enabled,
    directAccessGrantsEnabled: .direct_access_grants_enabled,
    serviceAccountsEnabled: .service_accounts_enabled,
    fullScopeAllowed: .full_scope_allowed,
    redirectUris: .valid_redirect_uris,
    webOrigins: .web_origins,
    defaultClientScopes: .default_scopes,
    optionalClientScopes: .optional_scopes
  }
  + (if .access_type == "confidential" then {
      clientAuthenticatorType: "client-secret",
      secret: .client_secret
    } else {} end)
  + (if (.base_url | length) > 0 then {baseUrl: .base_url} else {} end)
  + (if (.admin_url | length) > 0 then {adminUrl: .admin_url} else {} end)
  + (if (.root_url | length) > 0 then {rootUrl: .root_url} else {} end)
  + (if (.post_logout_redirect_uris | length) > 0 then {
      attributes: {"post.logout.redirect.uris": (.post_logout_redirect_uris | join("##"))}
    } else {} end)' "${client_json}" > "${payload}"

  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  if [[ -n "${client_id_value}" ]]; then
    api PUT "realms/$(urlencode "${realm}")/clients/${client_id_value}" "${payload}" >/dev/null
  else
    api POST "realms/$(urlencode "${realm}")/clients" "${payload}" >/dev/null
  fi
}

upsert_client_mapper() {
  local realm="$1"
  local client_identifier="$2"
  local mapper_json="$3"
  local client_id_value
  local mapper_name
  local existing_id
  local payload
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  mapper_name="$(jq -r '.name' "${mapper_json}")"
  payload="${TMPDIR}/mapper-${realm}-${client_identifier}-${mapper_name}.json"

  jq '{
    name: .name,
    protocol: "openid-connect",
    protocolMapper: .protocol_mapper,
    consentRequired: false,
    config: .config
  }' "${mapper_json}" > "${payload}"

  existing_id="$(client_protocol_mapper_id "${realm}" "${client_id_value}" "${mapper_name}")"
  if [[ -n "${existing_id}" ]]; then
    api DELETE "realms/$(urlencode "${realm}")/clients/${client_id_value}/protocol-mappers/models/${existing_id}" >/dev/null
  fi
  api POST "realms/$(urlencode "${realm}")/clients/${client_id_value}/protocol-mappers/models" "${payload}" >/dev/null
}

delete_client_mapper_if_present() {
  local realm="$1"
  local client_identifier="$2"
  local mapper_name="$3"
  local client_id_value
  local existing_id
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  existing_id="$(client_protocol_mapper_id "${realm}" "${client_id_value}" "${mapper_name}")"
  if [[ -n "${existing_id}" ]]; then
    api DELETE "realms/$(urlencode "${realm}")/clients/${client_id_value}/protocol-mappers/models/${existing_id}" >/dev/null
  fi
}

component_payload() {
  local source_json="$1"
  local parent_id="$2"
  local payload="$3"

  jq --arg parent_id "${parent_id}" '
    def config_arrays:
      with_entries(
        .value = (
          if .value == null then []
          elif (.value | type) == "array" then [.value[] | tostring]
          else [(.value | tostring)]
          end
        )
      );
    {
      name: .name,
      providerId: .provider_id,
      providerType: .provider_type,
      parentId: $parent_id,
      config: ((.component_config // .config // {}) | config_arrays)
    }' "${source_json}" > "${payload}"
}

upsert_component() {
  local realm="$1"
  local component_json="$2"
  local component_name
  local existing_id
  local parent_id
  local provider_type
  local payload

  component_name="$(jq -r '.name' "${component_json}")"
  parent_id="$(jq -r '.parentId' "${component_json}")"
  provider_type="$(jq -r '.providerType' "${component_json}")"
  payload="${TMPDIR}/component-${realm}-${component_name}.json"
  existing_id="$(component_id "${realm}" "${parent_id}" "${provider_type}" "${component_name}")"

  if [[ -n "${existing_id}" ]]; then
    jq --arg id "${existing_id}" '.id = $id' "${component_json}" > "${payload}"
    api PUT "realms/$(urlencode "${realm}")/components/${existing_id}" "${payload}" >/dev/null
    printf '%s\n' "${existing_id}"
  else
    api POST "realms/$(urlencode "${realm}")/components" "${component_json}" >/dev/null
    component_id "${realm}" "${parent_id}" "${provider_type}" "${component_name}"
  fi
}

sync_ldap_mapper() {
  local realm="$1"
  local federation_id="$2"
  local mapper_id="$3"

  api POST "realms/$(urlencode "${realm}")/user-storage/${federation_id}/mappers/${mapper_id}/sync?direction=fedToKeycloak" >/dev/null
}

configure_user_federation() {
  local realm="$1"
  local federation_json="$2"
  local realm_id
  local federation_file
  local federation_id
  local mapper_file
  local mapper_id
  local mapper_name

  realm_id="$(realm_uuid "${realm}")"
  federation_file="${TMPDIR}/federation-${realm}-$(jq -r '.name' "${federation_json}").json"
  component_payload "${federation_json}" "${realm_id}" "${federation_file}"
  federation_id="$(upsert_component "${realm}" "${federation_file}")"

  if [[ -z "${federation_id}" ]]; then
    echo "[keycloak-api] could not resolve federation component ${realm}/$(jq -r '.name' "${federation_json}")" >&2
    exit 1
  fi

  jq -c '.mappers[]?' "${federation_json}" | while IFS= read -r mapper; do
    mapper_name="$(jq -r '.name' <<< "${mapper}")"
    mapper_file="${TMPDIR}/federation-mapper-${realm}-${mapper_name}.json"
    printf '%s\n' "${mapper}" > "${TMPDIR}/federation-mapper-input.json"
    component_payload "${TMPDIR}/federation-mapper-input.json" "${federation_id}" "${mapper_file}"
    upsert_component "${realm}" "${mapper_file}" >/dev/null
  done

  if [[ "$(jq -r '.group_federation == null' "${federation_json}")" == "false" ]]; then
    mapper_name="$(jq -r '.group_federation.name' "${federation_json}")"
    mapper_file="${TMPDIR}/group-federation-mapper-${realm}-${mapper_name}.json"
    jq '.group_federation' "${federation_json}" > "${TMPDIR}/group-federation-input.json"
    component_payload "${TMPDIR}/group-federation-input.json" "${federation_id}" "${mapper_file}"
    mapper_id="$(upsert_component "${realm}" "${mapper_file}")"
    if [[ -n "${mapper_id}" ]]; then
      sync_ldap_mapper "${realm}" "${federation_id}" "${mapper_id}" || true
    fi
  fi
}

upsert_group() {
  local realm="$1"
  local group_json="$2"
  local group_name
  local existing_id
  local payload
  group_name="$(jq -r '.name' "${group_json}")"
  payload="${TMPDIR}/group-payload-${realm}-${group_name}.json"

  jq '{name: .name, path: ("/" + .name), attributes: {}, subGroups: [], description: .description}' "${group_json}" > "${payload}"
  existing_id="$(group_id "${realm}" "${group_name}")"
  if [[ -n "${existing_id}" ]]; then
    api PUT "realms/$(urlencode "${realm}")/groups/${existing_id}" "${payload}" >/dev/null
  else
    api POST "realms/$(urlencode "${realm}")/groups" "${payload}" >/dev/null
  fi
}

assign_user_group() {
  local realm="$1"
  local username="$2"
  local group_id_value="$3"
  local user_id_value

  user_id_value="$(user_id "${realm}" "${username}")"
  if [[ -z "${user_id_value}" ]]; then
    echo "[keycloak-api] could not resolve configured group member ${realm}/${username}" >&2
    return 1
  fi

  api PUT "realms/$(urlencode "${realm}")/users/${user_id_value}/groups/${group_id_value}" >/dev/null
}

ensure_client_role() {
  local realm="$1"
  local client_id_value="$2"
  local role_name="$3"
  local payload
  if api_allow_404 GET "realms/$(urlencode "${realm}")/clients/${client_id_value}/roles/$(urlencode "${role_name}")" >/dev/null; then
    return 0
  fi
  payload="${TMPDIR}/role-${realm}-${client_id_value}-${role_name}.json"
  json_file "${payload}" --arg name "${role_name}" '{name: $name, description: "OIDC login gate role"}'
  api POST "realms/$(urlencode "${realm}")/clients/${client_id_value}/roles" "${payload}" >/dev/null
}

assign_group_client_role() {
  local realm="$1"
  local group_name="$2"
  local client_identifier="$3"
  local role_name="$4"
  local group_id_value
  local client_id_value
  local role_payload
  group_id_value="$(group_id_by_path "${realm}" "/${group_name}" 2>/dev/null || true)"
  if [[ -z "${group_id_value}" ]]; then
    group_id_value="$(group_id "${realm}" "${group_name}" 2>/dev/null || true)"
  fi
  if [[ -z "${group_id_value}" ]]; then
    echo "[keycloak-api] warning: skipping login gate role for missing group ${realm}/${group_name}" >&2
    return 0
  fi
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"
  role_payload="${TMPDIR}/role-map-${realm}-${group_name}-${client_identifier}-${role_name}.json"
  role_json "${realm}" "${client_id_value}" "${role_name}" | jq '[.]' > "${role_payload}"
  api POST "realms/$(urlencode "${realm}")/groups/${group_id_value}/role-mappings/clients/${client_id_value}" "${role_payload}" >/dev/null
}

assign_group_realm_management_role() {
  local realm="$1"
  local group_id_value="$2"
  local role_name="$3"
  local realm_management_client_id
  local role_payload
  realm_management_client_id="$(client_uuid "${realm}" "realm-management")"
  role_payload="${TMPDIR}/realm-management-${realm}-${group_id_value}-${role_name}.json"
  role_json "${realm}" "${realm_management_client_id}" "${role_name}" | jq '[.]' > "${role_payload}"
  api POST "realms/$(urlencode "${realm}")/groups/${group_id_value}/role-mappings/clients/${realm_management_client_id}" "${role_payload}" >/dev/null
}

configure_client_service_account_roles() {
  local realm="$1"
  local client_json="$2"
  local client_identifier
  local service_account_id

  if [[ "$(jq -r '.service_account_realm_management_roles | length' "${client_json}")" -eq 0 ]]; then
    return 0
  fi

  client_identifier="$(jq -r '.client_id' "${client_json}")"
  if [[ "$(jq -r '.service_accounts_enabled' "${client_json}")" != "true" ]]; then
    echo "[keycloak-api] ${realm}/${client_identifier}: service account roles configured but service account disabled" >&2
    exit 1
  fi

  service_account_id="$(service_account_user_id "${realm}" "${client_identifier}")"
  if [[ -z "${service_account_id}" ]]; then
    echo "[keycloak-api] could not resolve service account user ${realm}/${client_identifier}" >&2
    exit 1
  fi

  jq -r '.service_account_realm_management_roles[]' "${client_json}" | while IFS= read -r role_name; do
    assign_user_client_role "${realm}" "${service_account_id}" "realm-management" "${role_name}"
    assign_client_scope_client_role "${realm}" "${client_identifier}" "realm-management" "${role_name}"
  done
}

configure_login_gate() {
  local realm="$1"
  local client_json="$2"
  local client_identifier
  local role_name
  local flow_alias
  local client_id_value
  local flow_id_value
  local parent_flow_alias
  local subflow_alias
  local condition_id
  local deny_id
  local payload

  client_identifier="$(jq -r '.client_id' "${client_json}")"
  role_name="$(jq -r '.login_role_name' "${client_json}")"
  flow_alias="$(jq -r '.login_browser_flow_alias' "${client_json}")"
  parent_flow_alias="${flow_alias} forms"
  subflow_alias="${flow_alias}-post-login-group-gate"
  client_id_value="$(client_uuid "${realm}" "${client_identifier}")"

  ensure_client_role "${realm}" "${client_id_value}" "${role_name}"

  flow_id_value="$(flow_id_by_alias "${realm}" "${flow_alias}")"
  if [[ -z "${flow_id_value}" ]]; then
    payload="${TMPDIR}/flow-copy-${realm}-${client_identifier}.json"
    json_file "${payload}" --arg newName "${flow_alias}" '{newName: $newName}'
    api POST "realms/$(urlencode "${realm}")/authentication/flows/browser/copy" "${payload}" >/dev/null
    flow_id_value="$(flow_id_by_alias "${realm}" "${flow_alias}")"
  fi

  if [[ -z "${flow_id_value}" ]]; then
    echo "[keycloak-api] could not resolve flow ${realm}/${flow_alias}" >&2
    exit 1
  fi

  if [[ -z "$(execution_by_display "${realm}" "${parent_flow_alias}" "${subflow_alias}")" ]]; then
    payload="${TMPDIR}/subflow-${realm}-${client_identifier}.json"
    json_file "${payload}" \
      --arg alias "${subflow_alias}" \
      --arg description "Deny ${client_identifier} login unless the configured group role is present" \
      '{alias: $alias, type: "basic-flow", provider: "basic-flow", description: $description}'
    api POST "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${parent_flow_alias}")/executions/flow" "${payload}" >/dev/null
  fi

  payload="${TMPDIR}/subflow-requirement-${realm}-${client_identifier}.json"
  json_file "${payload}" \
    --arg id "$(execution_by_display "${realm}" "${parent_flow_alias}" "${subflow_alias}")" \
    '{id: $id, requirement: "CONDITIONAL", priority: 30}'
  api PUT "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${parent_flow_alias}")/executions" "${payload}" >/dev/null

  condition_id="$(execution_by_provider "${realm}" "${subflow_alias}" "conditional-user-role")"
  if [[ -z "${condition_id}" ]]; then
    payload="${TMPDIR}/condition-execution-${realm}-${client_identifier}.json"
    json_file "${payload}" '{provider: "conditional-user-role"}'
    api POST "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${subflow_alias}")/executions/execution" "${payload}" >/dev/null
    condition_id="$(execution_by_provider "${realm}" "${subflow_alias}" "conditional-user-role")"
  fi

  deny_id="$(execution_by_provider "${realm}" "${subflow_alias}" "deny-access-authenticator")"
  if [[ -z "${deny_id}" ]]; then
    payload="${TMPDIR}/deny-execution-${realm}-${client_identifier}.json"
    json_file "${payload}" '{provider: "deny-access-authenticator"}'
    api POST "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${subflow_alias}")/executions/execution" "${payload}" >/dev/null
    deny_id="$(execution_by_provider "${realm}" "${subflow_alias}" "deny-access-authenticator")"
  fi

  payload="${TMPDIR}/condition-requirement-${realm}-${client_identifier}.json"
  json_file "${payload}" --arg id "${condition_id}" '{id: $id, requirement: "REQUIRED"}'
  api PUT "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${subflow_alias}")/executions" "${payload}" >/dev/null
  payload="${TMPDIR}/deny-requirement-${realm}-${client_identifier}.json"
  json_file "${payload}" --arg id "${deny_id}" '{id: $id, requirement: "REQUIRED"}'
  api PUT "realms/$(urlencode "${realm}")/authentication/flows/$(urlencode "${subflow_alias}")/executions" "${payload}" >/dev/null

  payload="${TMPDIR}/condition-config-${realm}-${client_identifier}.json"
  json_file "${payload}" \
    --arg alias "${subflow_alias}-condition" \
    --arg role "${client_identifier}.${role_name}" \
    '{alias: $alias, config: {condUserRole: $role, negate: "true"}}'
  api POST "realms/$(urlencode "${realm}")/authentication/executions/${condition_id}/config" "${payload}" >/dev/null 2>&1 || true

  payload="${TMPDIR}/deny-config-${realm}-${client_identifier}.json"
  json_file "${payload}" \
    --arg alias "${subflow_alias}-deny" \
    --arg message "${client_identifier}-group-required" \
    '{alias: $alias, config: {denyErrorMessage: $message}}'
  api POST "realms/$(urlencode "${realm}")/authentication/executions/${deny_id}/config" "${payload}" >/dev/null 2>&1 || true

  payload="${TMPDIR}/client-flow-${realm}-${client_identifier}.json"
  api GET "realms/$(urlencode "${realm}")/clients/${client_id_value}" |
    jq --arg flow_id "${flow_id_value}" '.authenticationFlowBindingOverrides = ((.authenticationFlowBindingOverrides // {}) + {browser: $flow_id})' > "${payload}"
  api PUT "realms/$(urlencode "${realm}")/clients/${client_id_value}" "${payload}" >/dev/null

  jq -r '.login_allowed_groups[]?' "${client_json}" | while IFS= read -r group_name; do
    assign_group_client_role "${realm}" "${group_name}" "${client_identifier}" "${role_name}"
  done
}

configure_realm() {
  local realm_json="$1"
  local realm
  local federation_file
  local group_file
  local client_file
  local mapper_file
  local group_id_value
  realm="$(jq -r '.name' "${realm_json}")"

  echo "[keycloak-api] realm ${realm}: settings"
  upsert_realm "${realm_json}"

  jq -c '.user_federation[]?' "${realm_json}" | while IFS= read -r federation; do
    federation_file="${TMPDIR}/federation-input.json"
    printf '%s\n' "${federation}" > "${federation_file}"
    echo "[keycloak-api] realm ${realm}: user federation $(jq -r '.name' "${federation_file}")"
    configure_user_federation "${realm}" "${federation_file}"
  done

  jq -c '.oidc_clients[]' "${realm_json}" | while IFS= read -r client; do
    client_file="${TMPDIR}/client-input.json"
    printf '%s\n' "${client}" > "${client_file}"
    echo "[keycloak-api] realm ${realm}: client $(jq -r '.client_id' "${client_file}")"
    upsert_client "${realm}" "${client_file}"
    configure_client_service_account_roles "${realm}" "${client_file}"
    jq -c '.mappers[]?' "${client_file}" | while IFS= read -r mapper; do
      mapper_file="${TMPDIR}/mapper-input.json"
      printf '%s\n' "${mapper}" > "${mapper_file}"
      upsert_client_mapper "${realm}" "$(jq -r '.client_id' "${client_file}")" "${mapper_file}"
    done
    jq -r '.removed_mappers[]?' "${client_file}" | while IFS= read -r mapper_name; do
      delete_client_mapper_if_present "${realm}" "$(jq -r '.client_id' "${client_file}")" "${mapper_name}"
    done
  done

  jq -c '.groups[]' "${realm_json}" | while IFS= read -r group; do
    group_file="${TMPDIR}/group-input.json"
    printf '%s\n' "${group}" > "${group_file}"
    echo "[keycloak-api] realm ${realm}: group $(jq -r '.name' "${group_file}")"
    upsert_group "${realm}" "${group_file}"
    group_id_value="$(wait_for_group "${realm}" "$(jq -r '.name' "${group_file}")")"
    if [[ "$(jq -r '.realm_admin' "${group_file}")" == "true" ]]; then
      assign_group_realm_management_role "${realm}" "${group_id_value}" "realm-admin"
    fi
    if [[ "$(jq -r '.included_ldap_groups | length' "${group_file}")" -gt 0 ]]; then
      assign_group_realm_management_role "${realm}" "${group_id_value}" "query-users"
      assign_group_realm_management_role "${realm}" "${group_id_value}" "query-groups"
      assign_group_realm_management_role "${realm}" "${group_id_value}" "view-users"
      jq -c '.included_ldap_groups[]' "${group_file}" | while IFS= read -r ldap_group; do
        wait_for_group "${realm}" "$(jq -r '.group_name' <<< "${ldap_group}")" >/dev/null
      done
    fi
    jq -r '.extra_members[]?' "${group_file}" | while IFS= read -r username; do
      assign_user_group "${realm}" "${username}" "${group_id_value}"
    done
  done

  jq -c '.oidc_clients[] | select((.login_allowed_groups // []) | length > 0)' "${realm_json}" | while IFS= read -r client; do
    client_file="${TMPDIR}/client-gate-input.json"
    printf '%s\n' "${client}" > "${client_file}"
    echo "[keycloak-api] realm ${realm}: login gate $(jq -r '.client_id' "${client_file}")"
    configure_login_gate "${realm}" "${client_file}"
  done

  echo "[keycloak-api] realm ${realm}: done"
}

require_cmd curl
require_cmd jq
require_env KEYCLOAK_URL
require_env KEYCLOAK_ADMIN_USER
require_env KEYCLOAK_ADMIN_PASSWORD
require_env KEYCLOAK_CONFIG_CLIENT_ID
require_env KEYCLOAK_REALMS_JSON

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
ACCESS_TOKEN=""

printf '%s\n' "${KEYCLOAK_REALMS_JSON}" > "${TMPDIR}/realms.json"

echo "[keycloak-api] waiting for admin API"
until login >/dev/null 2>&1; do
  printf '.'
  sleep 5
done
printf '\n'

echo "[keycloak-api] ensuring permanent master admin access"
ensure_master_admin_user
configure_master_realm_settings

jq -c '.[]' "${TMPDIR}/realms.json" | while IFS= read -r realm; do
  realm_file="${TMPDIR}/realm-input.json"
  printf '%s\n' "${realm}" > "${realm_file}"
  configure_realm "${realm_file}"
done

echo "[keycloak-api] all configured realms are done"
