locals {
  identity_namespace = "identity"

  keycloak_hostname        = "keycloak.${local.domain}"
  keycloak_tls_secret_name = "keycloak-tls"
  keycloak_image_tag       = "26.6.1"

  keycloak_admin_username        = "admin"
  keycloak_admin_password_length = 24

  keycloak_db_name         = "keycloak"
  keycloak_db_username     = "keycloak"
  postgres_image_tag       = "18.3"
  postgres_pvc_size        = "8Gi"
  postgres_password_length = 24

  postgres_storage_class = "${local.ceph_name_prefix}-rbd-ec"
  rancher_url            = "https://rancher.${local.domain}"
  portainer_url          = "https://portainer.${local.domain}"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = local.identity_namespace
      secret_name = local.keycloak_tls_secret_name
    },
  ]

  keycloak_realms = [
    {
      name = "company"

      settings = {
        save_user_events  = true
        save_admin_events = true
      }

      groups = [
        {
          name          = "admins"
          description   = "Realm administrators"
          realm_admin   = true
          extra_members = []
          included_ldap_groups = [
            {
              federation_name = "company-ldap"
              group_dn        = "CN=KC_COMPANY_ADMINS,OU=Groups,DC=company,DC=com"
            },
          ]
        },
        {
          name          = "k8s-admins"
          description   = "Shared Kubernetes platform administrators for Rancher and Portainer"
          extra_members = []
          included_ldap_groups = [
            {
              federation_name = "company-ldap"
              group_dn        = "CN=KC_K8S_ADMINS,OU=Groups,DC=company,DC=com"
            },
          ]
        },
      ]

      oidc_clients = [
        {
          client_id                    = "rancher"
          name                         = "Rancher"
          description                  = "OIDC client for Rancher login"
          access_type                  = "confidential"
          client_secret_length         = 32
          valid_redirect_uris          = ["${local.rancher_url}/verify-auth"]
          post_logout_redirect_uris    = ["${local.rancher_url}/*"]
          web_origins                  = [local.rancher_url]
          base_url                     = local.rancher_url
          admin_url                    = local.rancher_url
          standard_flow_enabled        = true
          direct_access_grants_enabled = false
          service_accounts_enabled     = false
          full_scope_allowed           = false
          include_groups_claim         = true
          groups_claim_name            = "groups"
          groups_claim_full_path       = false
          default_scopes               = ["profile", "email", "roles"]
          optional_scopes              = ["offline_access"]
          mappers = [
            {
              name            = "full_group_path"
              protocol_mapper = "oidc-group-membership-mapper"
              config = {
                "access.token.claim"        = "true"
                "claim.name"                = "full_group_path"
                "full.path"                 = "true"
                "id.token.claim"            = "true"
                "introspection.token.claim" = "true"
                "jsonType.label"            = "String"
                "multivalued"               = "true"
                "userinfo.token.claim"      = "true"
              }
            },
            {
              name            = "client-audience"
              protocol_mapper = "oidc-audience-mapper"
              config = {
                "access.token.claim"        = "true"
                "included.client.audience"  = "rancher"
                "id.token.claim"            = "false"
                "introspection.token.claim" = "false"
              }
            },
          ]
        },
        {
          client_id                    = "portainer"
          name                         = "Portainer"
          description                  = "OIDC client for Portainer login"
          access_type                  = "confidential"
          client_secret_length         = 32
          login_allowed_groups         = ["k8s-admins"]
          valid_redirect_uris          = ["${local.portainer_url}/"]
          post_logout_redirect_uris    = ["${local.portainer_url}/", "${local.portainer_url}/*"]
          web_origins                  = [local.portainer_url]
          base_url                     = local.portainer_url
          admin_url                    = local.portainer_url
          standard_flow_enabled        = true
          direct_access_grants_enabled = false
          service_accounts_enabled     = false
          full_scope_allowed           = false
          include_groups_claim         = true
          groups_claim_name            = "groups"
          groups_claim_full_path       = false
          default_scopes               = ["profile", "email", "roles"]
          optional_scopes              = ["offline_access"]
          mappers = [
            {
              name            = "client-audience"
              protocol_mapper = "oidc-audience-mapper"
              config = {
                "access.token.claim"        = "true"
                "included.client.audience"  = "portainer"
                "id.token.claim"            = "false"
                "introspection.token.claim" = "false"
              }
            },
          ]
        },
      ]

      user_federation = [
        {
          name            = "company-ldap"
          provider_id     = "ldap"
          vendor          = "ad"
          enabled         = true
          edit_mode       = "READ_ONLY"
          import_users    = true
          bind_dn         = "bind-user"
          bind_credential = "replace-me"

          connection = {
            url                = "ldap://ldap-server:389"
            users_dn           = "OU=Users,DC=company,DC=com"
            auth_type          = "simple"
            start_tls          = false
            use_truststore_spi = "always"
            connection_pooling = true
            connection_trace   = false
            pagination         = true
            read_timeout       = 10000
            search_scope       = 2
          }

          sync = {
            sync_registrations   = true
            changed_sync_period  = -1
            full_sync_period     = -1
            remove_invalid_users = true
          }

          kerberos = {
            allow_kerberos_authentication            = false
            use_kerberos_for_password_authentication = false
            kerberos_principal_attribute             = "userPrincipalName"
          }

          ldap_user = {
            username_ldap_attribute         = "sAMAccountName"
            rdn_ldap_attribute              = "cn"
            uuid_ldap_attribute             = "objectGUID"
            user_object_classes             = "person, organizationalPerson, user"
            trust_email                     = true
            validate_password_policy        = false
            enable_ldap_password_policy     = false
            use_password_modify_extended_op = false
          }

          group_federation = {
            name                                 = "company-groups"
            groups_dn                            = "OU=Groups,DC=company,DC=com"
            group_name_ldap_attribute            = "cn"
            group_object_classes                 = "group"
            preserve_group_inheritance           = false
            membership_ldap_attribute            = "member"
            membership_attribute_type            = "DN"
            membership_user_ldap_attribute       = "distinguishedName"
            groups_ldap_filter                   = ""
            mode                                 = "READ_ONLY"
            user_groups_retrieve_strategy        = "GET_GROUPS_FROM_USER_MEMBEROF_ATTRIBUTE"
            memberof_ldap_attribute              = "memberOf"
            mapped_group_attributes              = ""
            drop_non_existing_groups_during_sync = false
            ignore_missing_groups                = true
            groups_path                          = "/"
          }

          mappers = [
            {
              name        = "username"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "sAMAccountName"
                "attribute.force.default"     = "true"
                "is.mandatory.in.ldap"        = "true"
                "is.binary.attribute"         = "false"
                "always.read.value.from.ldap" = "false"
                "read.only"                   = "true"
                "user.model.attribute"        = "username"
              }
            },
            {
              name        = "first name"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "givenName"
                "is.mandatory.in.ldap"        = "true"
                "always.read.value.from.ldap" = "true"
                "read.only"                   = "true"
                "user.model.attribute"        = "firstName"
              }
            },
            {
              name        = "email"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "mail"
                "is.mandatory.in.ldap"        = "false"
                "always.read.value.from.ldap" = "false"
                "read.only"                   = "true"
                "user.model.attribute"        = "email"
              }
            },
            {
              name        = "creation date"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "whenCreated"
                "is.mandatory.in.ldap"        = "false"
                "read.only"                   = "true"
                "always.read.value.from.ldap" = "true"
                "user.model.attribute"        = "createTimestamp"
              }
            },
            {
              name        = "MSAD account controls"
              provider_id = "msad-user-account-control-mapper"
              config = {
                "always.read.enabled.value.from.ldap" = "true"
              }
            },
            {
              name        = "last name"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "sn"
                "is.mandatory.in.ldap"        = "true"
                "always.read.value.from.ldap" = "true"
                "read.only"                   = "true"
                "user.model.attribute"        = "lastName"
              }
            },
            {
              name        = "Kerberos principal attribute mapper"
              provider_id = "kerberos-principal-attribute-mapper"
              config      = {}
            },
            {
              name        = "modify date"
              provider_id = "user-attribute-ldap-mapper"
              config = {
                "ldap.attribute"              = "whenChanged"
                "is.mandatory.in.ldap"        = "false"
                "always.read.value.from.ldap" = "true"
                "read.only"                   = "true"
                "user.model.attribute"        = "modifyTimestamp"
              }
            },
          ]
        },
      ]
    },
  ]
}
