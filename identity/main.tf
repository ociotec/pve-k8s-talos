terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.8.1"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

variable "skip_identity" {
  type        = bool
  default     = false
  description = "Skip identity services."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  configured_keycloak_realms = try(local.keycloak_realms, [])
  keycloak_realm_base_definitions = [
    for realm in local.configured_keycloak_realms : {
      name = realm.name
      settings = {
        save_user_events  = try(realm.settings.save_user_events, false)
        save_admin_events = try(realm.settings.save_admin_events, false)
      }
      groups = [
        for group in try(realm.groups, []) : {
          name        = group.name
          description = try(group.description, "")
          realm_admin = try(group.realm_admin, false)
          extra_members = distinct(concat(
            try(group.extra_members, []),
            try(group.members, [])
          ))
          included_ldap_groups = [
            for ldap_group in try(group.included_ldap_groups, []) : {
              federation_name = try(ldap_group.federation_name, "")
              group_dn        = ldap_group.group_dn
              group_name      = trimspace(try(ldap_group.group_name, "")) != "" ? ldap_group.group_name : try(regex("^CN=([^,]+)", ldap_group.group_dn)[0], ldap_group.group_dn)
            }
          ]
        }
      ]
      user_federation = [
        for federation in try(realm.user_federation, []) : {
          name        = federation.name
          provider_id = try(federation.provider_id, "ldap")
          provider_type = try(
            federation.provider_type,
            "org.keycloak.storage.UserStorageProvider"
          )
          component_config = {
            pagination                           = tostring(try(federation.connection.pagination, true))
            fullSyncPeriod                       = tostring(try(federation.sync.full_sync_period, -1))
            connectionTrace                      = tostring(try(federation.connection.connection_trace, false))
            startTls                             = tostring(try(federation.connection.start_tls, false))
            usersDn                              = federation.connection.users_dn
            connectionPooling                    = tostring(try(federation.connection.connection_pooling, true))
            cachePolicy                          = try(federation.cache_policy, "DEFAULT")
            useKerberosForPasswordAuthentication = tostring(try(federation.kerberos.use_kerberos_for_password_authentication, false))
            importEnabled                        = tostring(try(federation.import_users, true))
            enabled                              = tostring(try(federation.enabled, true))
            bindCredential                       = federation.bind_credential
            bindDn                               = federation.bind_dn
            changedSyncPeriod                    = tostring(try(federation.sync.changed_sync_period, -1))
            usernameLDAPAttribute                = federation.ldap_user.username_ldap_attribute
            vendor                               = federation.vendor
            uuidLDAPAttribute                    = federation.ldap_user.uuid_ldap_attribute
            connectionUrl                        = federation.connection.url
            allowKerberosAuthentication          = tostring(try(federation.kerberos.allow_kerberos_authentication, false))
            syncRegistrations                    = tostring(try(federation.sync.sync_registrations, true))
            authType                             = try(federation.connection.auth_type, "simple")
            krbPrincipalAttribute                = try(federation.kerberos.kerberos_principal_attribute, "userPrincipalName")
            searchScope                          = tostring(try(federation.connection.search_scope, 2))
            useTruststoreSpi                     = try(federation.connection.use_truststore_spi, "always")
            usePasswordModifyExtendedOp          = tostring(try(federation.ldap_user.use_password_modify_extended_op, false))
            trustEmail                           = tostring(try(federation.ldap_user.trust_email, false))
            userObjectClasses                    = federation.ldap_user.user_object_classes
            removeInvalidUsersEnabled            = tostring(try(federation.sync.remove_invalid_users, true))
            rdnLDAPAttribute                     = federation.ldap_user.rdn_ldap_attribute
            editMode                             = try(federation.edit_mode, "READ_ONLY")
            readTimeout                          = tostring(try(federation.connection.read_timeout, 10000))
            validatePasswordPolicy               = tostring(try(federation.ldap_user.validate_password_policy, false))
            enableLdapPasswordPolicy             = tostring(try(federation.ldap_user.enable_ldap_password_policy, false))
          }
          mappers = [
            for mapper in try(federation.mappers, []) : {
              name        = mapper.name
              provider_id = mapper.provider_id
              provider_type = try(
                mapper.provider_type,
                "org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
              )
              config = try(mapper.config, {})
            }
          ]
          group_federation = try(federation.group_federation, null) == null ? null : {
            name          = try(federation.group_federation.name, format("%s-groups", federation.name))
            provider_id   = "group-ldap-mapper"
            provider_type = "org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
            config = {
              "groups.dn"                            = federation.group_federation.groups_dn
              "group.name.ldap.attribute"            = try(federation.group_federation.group_name_ldap_attribute, "cn")
              "group.object.classes"                 = try(federation.group_federation.group_object_classes, "group")
              "preserve.group.inheritance"           = tostring(try(federation.group_federation.preserve_group_inheritance, false))
              "membership.ldap.attribute"            = try(federation.group_federation.membership_ldap_attribute, "member")
              "membership.attribute.type"            = try(federation.group_federation.membership_attribute_type, "DN")
              "membership.user.ldap.attribute"       = try(federation.group_federation.membership_user_ldap_attribute, "distinguishedName")
              "groups.ldap.filter"                   = try(federation.group_federation.groups_ldap_filter, "")
              "mode"                                 = try(federation.group_federation.mode, "READ_ONLY")
              "user.roles.retrieve.strategy"         = try(federation.group_federation.user_groups_retrieve_strategy, "GET_GROUPS_FROM_USER_MEMBEROF_ATTRIBUTE")
              "memberof.ldap.attribute"              = try(federation.group_federation.memberof_ldap_attribute, "memberOf")
              "mapped.group.attributes"              = try(federation.group_federation.mapped_group_attributes, "")
              "drop.non.existing.groups.during.sync" = tostring(try(federation.group_federation.drop_non_existing_groups_during_sync, false))
              "ignore.missing.groups"                = tostring(try(federation.group_federation.ignore_missing_groups, true))
              "groups.path"                          = try(federation.group_federation.groups_path, "/")
            }
          }
        }
      ]
      oidc_clients = [
        for client in try(realm.oidc_clients, []) : {
          name                         = trimspace(try(client.name, "")) != "" ? client.name : client.client_id
          client_id                    = client.client_id
          description                  = try(client.description, "")
          enabled                      = try(client.enabled, true)
          access_type                  = try(client.access_type, "confidential")
          valid_redirect_uris          = distinct(try(client.valid_redirect_uris, []))
          web_origins                  = distinct(try(client.web_origins, []))
          post_logout_redirect_uris    = distinct(try(client.post_logout_redirect_uris, []))
          base_url                     = try(client.base_url, "")
          admin_url                    = try(client.admin_url, "")
          root_url                     = try(client.root_url, "")
          standard_flow_enabled        = try(client.standard_flow_enabled, true)
          direct_access_grants_enabled = try(client.direct_access_grants_enabled, false)
          service_accounts_enabled     = try(client.service_accounts_enabled, false)
          full_scope_allowed           = try(client.full_scope_allowed, false)
          client_secret                = try(client.client_secret, "")
          client_secret_length         = try(client.client_secret_length, 32)
          default_scopes               = distinct(try(client.default_scopes, []))
          optional_scopes              = distinct(try(client.optional_scopes, []))
          mappers = concat(
            try(client.include_groups_claim, false) ? [
              {
                name            = try(client.groups_claim_name, "groups")
                protocol_mapper = "oidc-group-membership-mapper"
                config = {
                  "access.token.claim"        = "false"
                  "claim.name"                = try(client.groups_claim_name, "groups")
                  "full.path"                 = tostring(try(client.groups_claim_full_path, true))
                  "id.token.claim"            = "false"
                  "introspection.token.claim" = "true"
                  "jsonType.label"            = "String"
                  "multivalued"               = "true"
                  "userinfo.token.claim"      = "true"
                }
              },
            ] : [],
            [
              for mapper in try(client.mappers, []) : {
                name            = mapper.name
                protocol_mapper = mapper.protocol_mapper
                config          = try(mapper.config, {})
              }
            ]
          )
        }
      ]
    }
  ]
  oidc_client_secret_requests = {
    for client in flatten([
      for realm in local.keycloak_realm_base_definitions : [
        for oidc_client in realm.oidc_clients : merge(oidc_client, {
          realm_name = realm.name
          key        = format("%s/%s", realm.name, oidc_client.client_id)
        })
      ]
    ]) : client.key => client
    if client.access_type == "confidential" && trimspace(client.client_secret) == ""
  }
  keycloak_realm_definitions = [
    for realm in local.keycloak_realm_base_definitions : merge(realm, {
      oidc_clients = [
        for client in realm.oidc_clients : merge(client, {
          client_secret = client.access_type == "confidential" ? (
            trimspace(client.client_secret) != "" ? client.client_secret : random_password.oidc_client_secret[format("%s/%s", realm.name, client.client_id)].result
          ) : ""
        })
      ]
    })
  ]
  keycloak_realm_config_script = trimspace(templatefile("${path.module}/keycloak-configure-realms.sh.tftpl", {
    keycloak_realms = local.keycloak_realm_definitions
  }))
  keycloak_enabled = trimspace(local.keycloak_hostname) != ""
  identity_resources = [
    for doc in split("\n---\n", templatefile("${path.module}/keycloak.yaml", {
      identity_namespace     = local.identity_namespace
      keycloak_hostname      = local.keycloak_hostname
      keycloak_image_tag     = local.keycloak_image_tag
      keycloak_tls_secret    = local.keycloak_tls_secret_name
      keycloak_db_name       = local.keycloak_db_name
      postgres_image_tag     = local.postgres_image_tag
      postgres_pvc_size      = local.postgres_pvc_size
      postgres_storage_class = local.postgres_storage_class
      keycloak_realms        = []
      keycloak_realms_script = ""
    })) :
    yamldecode(doc)
    if local.keycloak_enabled && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  keycloak_realms_job_enabled = local.keycloak_enabled && length(local.keycloak_realm_definitions) > 0

  identity_certificates = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  identity_ingress = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  identity_other = [
    for m in local.identity_resources : m
    if !contains(["Certificate", "Ingress", "Namespace"], try(m.kind, ""))
  ]
  identity_namespaces = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Namespace"
  ]
  identity_namespaces_by_id = {
    for i in range(length(local.identity_namespaces)) : tostring(i) => local.identity_namespaces[i]
  }
  identity_other_by_id = {
    for i in range(length(local.identity_other)) : tostring(i) => local.identity_other[i]
  }
  identity_certificates_by_id = {
    for i in range(length(local.identity_certificates)) : tostring(i) => local.identity_certificates[i]
  }
  identity_ingress_by_id = {
    for i in range(length(local.identity_ingress)) : tostring(i) => local.identity_ingress[i]
  }

  identity_tls_secrets = [
    for secret in local.tls_secrets : secret
    if format("%s/%s", secret.namespace, secret.secret_name) == format("%s/%s", local.identity_namespace, local.keycloak_tls_secret_name)
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.identity_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" && !var.skip_identity && local.keycloak_enabled ? [
    for secret in local.identity_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)
  ] : []
  missing_preissued_tls_secret_targets = [
    for target in local.expected_preissued_tls_secret_targets : target
    if !contains(keys(local.preissued_tls_secrets_by_target), target)
  ]
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

check "preissued_tls_secrets_unique" {
  assert {
    condition     = local.tls_source != "preissued" || length(local.identity_tls_secrets) == length(local.preissued_tls_secrets_by_target)
    error_message = "tls_secrets contains duplicate namespace/secret_name pairs for identity."
  }
}

check "preissued_tls_secrets_required" {
  assert {
    condition     = local.tls_source != "preissued" || var.skip_identity || !local.keycloak_enabled || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || var.skip_identity || !local.keycloak_enabled || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued identity tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

resource "kubernetes_manifest" "identity_namespaces" {
  for_each = !var.skip_identity ? local.identity_namespaces_by_id : tomap({})
  manifest = each.value
}

resource "random_password" "postgres_password" {
  count   = !var.skip_identity && local.keycloak_enabled ? 1 : 0
  length  = local.postgres_password_length
  special = false
}

resource "random_password" "keycloak_admin_password" {
  count   = !var.skip_identity && local.keycloak_enabled ? 1 : 0
  length  = local.keycloak_admin_password_length
  special = false
}

resource "random_password" "oidc_client_secret" {
  for_each = !var.skip_identity && local.keycloak_enabled ? local.oidc_client_secret_requests : tomap({})

  length  = each.value.client_secret_length
  special = false
}

resource "kubernetes_secret_v1" "keycloak_db" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  metadata {
    name      = "keycloak-db"
    namespace = local.identity_namespace
  }

  data = {
    username = local.keycloak_db_username
    password = random_password.postgres_password[0].result
    database = local.keycloak_db_name
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_secret_v1" "keycloak_admin" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  metadata {
    name      = "keycloak-admin"
    namespace = local.identity_namespace
  }

  data = {
    username = local.keycloak_admin_username
    password = random_password.keycloak_admin_password[0].result
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_manifest" "identity_other" {
  for_each = !var.skip_identity ? local.identity_other_by_id : tomap({})
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "spec.template.metadata.annotations",
    "spec.template.metadata.labels",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
      manifest.spec.template.metadata.annotations,
      manifest.spec.template.metadata.labels,
    ]
  }
  depends_on = [
    kubernetes_manifest.identity_namespaces,
    kubernetes_secret_v1.keycloak_db,
    kubernetes_secret_v1.keycloak_admin,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = !var.skip_identity && local.keycloak_enabled && local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source == "preissued" && !var.skip_identity && local.keycloak_enabled ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type       = "kubernetes.io/tls"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_manifest" "identity_certificates" {
  for_each = !var.skip_identity ? local.identity_certificates_by_id : tomap({})
  manifest = each.value
  depends_on = [
    kubernetes_manifest.identity_namespaces,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "identity_ingress" {
  for_each = !var.skip_identity ? local.identity_ingress_by_id : tomap({})
  manifest = each.value
  depends_on = [
    kubernetes_manifest.identity_other,
    kubernetes_manifest.identity_certificates,
    kubernetes_secret_v1.preissued_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

resource "kubernetes_job_v1" "identity_realms_job" {
  count = !var.skip_identity && local.keycloak_realms_job_enabled ? 1 : 0

  metadata {
    name      = "keycloak-configure-realms"
    namespace = local.identity_namespace
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = {
          app = "keycloak-configure-realms"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "keycloak-configure-realms"
          image = "quay.io/keycloak/keycloak:${local.keycloak_image_tag}"
          command = [
            "/bin/sh",
            "-ec",
            local.keycloak_realm_config_script,
          ]

          volume_mount {
            name       = "keycloak-admin"
            mount_path = "/keycloak-admin"
            read_only  = true
          }
        }

        volume {
          name = "keycloak-admin"

          secret {
            secret_name = "keycloak-admin"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.identity_other,
    kubernetes_manifest.identity_ingress,
  ]
}

output "keycloak_enabled" {
  value = local.keycloak_enabled && !var.skip_identity
}

output "keycloak_url" {
  value = local.keycloak_enabled && !var.skip_identity ? "https://${local.keycloak_hostname}" : null
}

output "keycloak_admin_user" {
  value = local.keycloak_enabled && !var.skip_identity ? local.keycloak_admin_username : null
}

output "keycloak_admin_password" {
  value     = local.keycloak_enabled && !var.skip_identity ? random_password.keycloak_admin_password[0].result : null
  sensitive = true
}

output "keycloak_oidc_client_metadata" {
  value = local.keycloak_enabled && !var.skip_identity ? {
    for realm in local.keycloak_realm_definitions :
    realm.name => {
      issuer_url = "https://${local.keycloak_hostname}/realms/${realm.name}"
      clients = {
        for client in realm.oidc_clients : client.client_id => {
          client_id                 = client.client_id
          access_type               = client.access_type
          redirect_uris             = client.valid_redirect_uris
          post_logout_redirect_uris = client.post_logout_redirect_uris
          web_origins               = client.web_origins
        }
      }
    }
  } : {}
}

output "keycloak_oidc_client_secrets" {
  value = local.keycloak_enabled && !var.skip_identity ? {
    for realm in local.keycloak_realm_definitions :
    realm.name => {
      for client in realm.oidc_clients :
      client.client_id => client.client_secret
      if client.access_type == "confidential"
    }
  } : {}
  sensitive = true
}

output "keycloak_realm_groups" {
  value = local.keycloak_enabled && !var.skip_identity ? {
    for realm in local.keycloak_realm_definitions :
    realm.name => {
      for group in realm.groups :
      group.name => {
        description          = group.description
        included_ldap_groups = group.included_ldap_groups
      }
    }
  } : {}
}
