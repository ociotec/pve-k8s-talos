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
          name        = "admins"
          description = "Realm administrators"
          realm_admin = true
          extra_members = []
          included_ldap_groups = [
            {
              federation_name = "company-ldap"
              group_dn        = "CN=KC_COMPANY_ADMINS,OU=Groups,DC=company,DC=com"
            },
          ]
        },
      ]

      user_federation = [
        {
          name         = "company-ldap"
          provider_id  = "ldap"
          vendor       = "ad"
          enabled      = true
          edit_mode    = "READ_ONLY"
          import_users = true
          bind_dn      = "bind-user"
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
            name                            = "company-groups"
            groups_dn                       = "OU=Groups,DC=company,DC=com"
            group_name_ldap_attribute       = "cn"
            group_object_classes            = "group"
            preserve_group_inheritance      = false
            membership_ldap_attribute       = "member"
            membership_attribute_type       = "DN"
            membership_user_ldap_attribute  = "distinguishedName"
            groups_ldap_filter              = ""
            mode                            = "READ_ONLY"
            user_groups_retrieve_strategy   = "GET_GROUPS_FROM_USER_MEMBEROF_ATTRIBUTE"
            memberof_ldap_attribute         = "memberOf"
            mapped_group_attributes         = ""
            drop_non_existing_groups_during_sync = false
            ignore_missing_groups           = true
            groups_path                     = "/"
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
