variable "skip_identity" {
  type        = bool
  default     = false
  description = "Skip identity services."
}

locals {
  identity_state_path = abspath("${path.module}/../identity/terraform.tfstate")
  keycloak_enabled    = try(data.terraform_remote_state.identity.outputs.keycloak_enabled, false)
  keycloak_url        = try(data.terraform_remote_state.identity.outputs.keycloak_url, "")
  keycloak_realms     = try(data.terraform_remote_state.identity.outputs.keycloak_realm_definitions, [])
  unsupported_keycloak_api_features = flatten([
    for realm in local.keycloak_realms : concat(
      length(try(realm.user_federation, [])) > 0 ? [format("%s/user_federation", realm.name)] : [],
      flatten([
        for group in try(realm.groups, []) : concat(
          length(try(group.extra_members, [])) > 0 ? [format("%s/groups/%s/extra_members", realm.name, group.name)] : [],
          length(try(group.included_ldap_groups, [])) > 0 ? [format("%s/groups/%s/included_ldap_groups", realm.name, group.name)] : []
        )
      ])
    )
  ])
}

data "terraform_remote_state" "identity" {
  backend = "local"

  config = {
    path = local.identity_state_path
  }
}

check "keycloak_api_supported_config" {
  assert {
    condition     = length(local.unsupported_keycloak_api_features) == 0
    error_message = format("identity-config API mode does not yet support these Keycloak features: %s", join(", ", local.unsupported_keycloak_api_features))
  }
}

resource "terraform_data" "keycloak_realms" {
  count = !var.skip_identity && local.keycloak_enabled && length(local.keycloak_realms) > 0 ? 1 : 0

  input = {
    keycloak_url = local.keycloak_url
    realms_sha   = sha256(jsonencode(local.keycloak_realms))
    script_sha   = filesha256("${path.module}/configure-keycloak-realms.sh")
  }

  triggers_replace = {
    keycloak_url = local.keycloak_url
    realms_sha   = sha256(jsonencode(local.keycloak_realms))
    run_id       = timestamp()
    script_sha   = filesha256("${path.module}/configure-keycloak-realms.sh")
  }

  provisioner "local-exec" {
    command = "${path.module}/configure-keycloak-realms.sh"

    environment = {
      KEYCLOAK_URL              = local.keycloak_url
      KEYCLOAK_ADMIN_USER       = data.terraform_remote_state.identity.outputs.keycloak_admin_user
      KEYCLOAK_ADMIN_PASSWORD   = data.terraform_remote_state.identity.outputs.keycloak_admin_password
      KEYCLOAK_CONFIG_CLIENT_ID = "identity-config"
      KEYCLOAK_REALMS_JSON      = jsonencode(local.keycloak_realms)
    }
  }
}

output "keycloak_configured" {
  value = !var.skip_identity && local.keycloak_enabled && length(local.keycloak_realms) > 0
}
