terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

variable "skip_platform" {
  type        = bool
  default     = false
  description = "Skip platform services."
}

data "terraform_remote_state" "identity" {
  count = !var.skip_platform && (
    trimspace(try(local.rancher_auth_keycloak_realm, "")) != "" ||
    trimspace(try(local.portainer_auth_keycloak_realm, "")) != ""
  ) ? 1 : 0

  backend = "local"
  config = {
    path = abspath("${path.root}/../identity/terraform.tfstate")
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  cluster_credentials                    = try(jsondecode(file("${path.module}/credentials.json")), {})
  platform_credentials                   = try(local.cluster_credentials.platform, {})
  platform_portainer_admin_password      = try(local.platform_credentials.portainer_admin_password, "")
  platform_rancher_bootstrap_password    = try(local.platform_credentials.rancher_bootstrap_password, "")
  rancher_enabled                        = trimspace(local.rancher_hostname) != ""
  rancher_hostname_value                 = local.rancher_hostname
  rancher_tls_secret_name_value          = local.rancher_tls_secret_name
  rancher_replicas_value                 = local.rancher_replicas
  rancher_version_value                  = try(local.rancher_version, "2.14.1")
  rancher_debug_value                    = try(local.rancher_debug, false)
  rancher_cpu_request_value              = try(local.rancher_cpu_request, "200m")
  rancher_cpu_limit_value                = try(local.rancher_cpu_limit, "1")
  rancher_mem_request_value              = try(local.rancher_mem_request, "2560Mi")
  rancher_mem_limit_value                = try(local.rancher_mem_limit, "2560Mi")
  rancher_private_ca_value               = local.rancher_private_ca
  rancher_bootstrap_length_value         = local.rancher_bootstrap_password_length
  rancher_auth_keycloak_realm_value      = trimspace(try(local.rancher_auth_keycloak_realm, ""))
  rancher_auth_allowed_group_value       = trimspace(try(local.rancher_auth_allowed_group, ""))
  rancher_auth_global_role_value         = trimspace(try(local.rancher_auth_global_role, "admin"))
  rancher_auth_access_mode_value         = trimspace(try(local.rancher_auth_access_mode, "restricted"))
  rancher_auth_enabled                   = local.rancher_enabled && !var.skip_platform && local.rancher_auth_keycloak_realm_value != "" && local.rancher_auth_allowed_group_value != ""
  portainer_admin_secret_name_value      = try(local.portainer_admin_secret_name, "portainer-admin")
  portainer_admin_password_length_value  = try(local.portainer_admin_password_length, 24)
  portainer_oauth_ca_secret_name_value   = try(local.portainer_oauth_ca_secret_name, "portainer-oauth-ca")
  portainer_auth_keycloak_realm_value    = trimspace(try(local.portainer_auth_keycloak_realm, ""))
  portainer_auth_user_identifier_value   = trimspace(try(local.portainer_auth_user_identifier, "preferred_username"))
  portainer_auth_scopes_value            = trimspace(try(local.portainer_auth_scopes, "openid profile email"))
  portainer_auth_sso_value               = try(local.portainer_auth_sso, true)
  portainer_auth_auto_create_users_value = try(local.portainer_auth_auto_create_users, true)
  portainer_auth_default_team_name_value = trimspace(try(
    local.portainer_auth_default_team_name,
    try(local.rancher_auth_allowed_group, "k8s-admins")
  ))
  portainer_auth_default_team_role_id_value        = try(local.portainer_auth_default_team_role_id, 1)
  portainer_auth_default_team_existing_users_value = try(local.portainer_auth_default_team_existing_users, [])
  portainer_auth_enabled                           = !var.skip_platform && trimspace(local.portainer_hostname) != "" && local.portainer_auth_keycloak_realm_value != ""
  identity_auth_enabled                            = local.rancher_auth_enabled || local.portainer_auth_enabled
  identity_realm_groups = local.identity_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_realm_groups,
    {}
  ) : {}
  identity_oidc_metadata = local.identity_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_metadata,
    {}
  ) : {}
  identity_oidc_client_secrets = try(local.cluster_credentials.identity.oidc_client_secrets, {})
  available_identity_realms    = keys(local.identity_oidc_metadata)
  rancher_oidc_issuer = local.rancher_auth_enabled ? try(
    local.identity_oidc_metadata[local.rancher_auth_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  rancher_oidc_client_id = local.rancher_auth_enabled ? try(
    local.identity_oidc_metadata[local.rancher_auth_keycloak_realm_value].clients["rancher"].client_id,
    ""
  ) : ""
  rancher_oidc_client_secret = local.rancher_auth_enabled ? try(
    local.identity_oidc_client_secrets[format("%s/rancher", local.rancher_auth_keycloak_realm_value)],
    ""
  ) : ""
  rancher_oidc_auth_endpoint        = local.rancher_oidc_issuer != "" ? format("%s/protocol/openid-connect/auth", local.rancher_oidc_issuer) : ""
  rancher_oidc_token_endpoint       = local.rancher_oidc_issuer != "" ? format("%s/protocol/openid-connect/token", local.rancher_oidc_issuer) : ""
  rancher_oidc_userinfo_endpoint    = local.rancher_oidc_issuer != "" ? format("%s/protocol/openid-connect/userinfo", local.rancher_oidc_issuer) : ""
  rancher_oidc_jwks_url             = local.rancher_oidc_issuer != "" ? format("%s/protocol/openid-connect/certs", local.rancher_oidc_issuer) : ""
  rancher_oidc_end_session_endpoint = local.rancher_oidc_issuer != "" ? format("%s/protocol/openid-connect/logout", local.rancher_oidc_issuer) : ""
  rancher_allowed_group_definition = local.rancher_auth_enabled ? try(
    local.identity_realm_groups[local.rancher_auth_keycloak_realm_value][local.rancher_auth_allowed_group_value],
    null
  ) : null
  rancher_auth_allowed_group_names = local.rancher_auth_enabled ? distinct(compact(concat(
    [local.rancher_auth_allowed_group_value],
    local.rancher_allowed_group_definition == null ? [] : [
      for ldap_group in try(local.rancher_allowed_group_definition.included_ldap_groups, []) : ldap_group.group_name
    ]
  ))) : []
  rancher_auth_allowed_principal_ids = [
    for group_name in local.rancher_auth_allowed_group_names : format("keycloakoidc_group://%s", group_name)
  ]
  rancher_auth_ca_content = local.rancher_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  portainer_oidc_issuer = local.portainer_auth_enabled ? try(
    local.identity_oidc_metadata[local.portainer_auth_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  portainer_oidc_client_id = local.portainer_auth_enabled ? try(
    local.identity_oidc_metadata[local.portainer_auth_keycloak_realm_value].clients["portainer"].client_id,
    ""
  ) : ""
  portainer_oidc_client_secret = local.portainer_auth_enabled ? try(
    local.identity_oidc_client_secrets[format("%s/portainer", local.portainer_auth_keycloak_realm_value)],
    ""
  ) : ""
  portainer_oidc_auth_endpoint        = local.portainer_oidc_issuer != "" ? format("%s/protocol/openid-connect/auth", local.portainer_oidc_issuer) : ""
  portainer_oidc_token_endpoint       = local.portainer_oidc_issuer != "" ? format("%s/protocol/openid-connect/token", local.portainer_oidc_issuer) : ""
  portainer_oidc_userinfo_endpoint    = local.portainer_oidc_issuer != "" ? format("%s/protocol/openid-connect/userinfo", local.portainer_oidc_issuer) : ""
  portainer_oidc_end_session_endpoint = local.portainer_oidc_issuer != "" ? format("%s/protocol/openid-connect/logout", local.portainer_oidc_issuer) : ""
  portainer_oauth_redirect_uri        = format("https://%s/", local.portainer_hostname)
  portainer_oauth_logout_uri = local.portainer_oidc_end_session_endpoint != "" ? format(
    "%s?client_id=%s&post_logout_redirect_uri=%s",
    local.portainer_oidc_end_session_endpoint,
    urlencode(local.portainer_oidc_client_id),
    urlencode(local.portainer_oauth_redirect_uri)
  ) : ""
  portainer_auth_ca_content = local.portainer_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  portainer_auth_ca_enabled = trimspace(local.portainer_auth_ca_content) != ""
  portainer_oauth_settings = local.portainer_auth_enabled ? {
    ClientID             = local.portainer_oidc_client_id
    ClientSecret         = local.portainer_oidc_client_secret
    AuthorizationURI     = local.portainer_oidc_auth_endpoint
    AccessTokenURI       = local.portainer_oidc_token_endpoint
    ResourceURI          = local.portainer_oidc_userinfo_endpoint
    RedirectURI          = local.portainer_oauth_redirect_uri
    UserIdentifier       = local.portainer_auth_user_identifier_value
    Scopes               = local.portainer_auth_scopes_value
    OAuthAutoCreateUsers = local.portainer_auth_auto_create_users_value
    DefaultTeamID        = 0
    SSO                  = local.portainer_auth_sso_value
    LogoutURI            = local.portainer_oauth_logout_uri
  } : null
  portainer_oauth_payload = local.portainer_auth_enabled ? {
    AuthenticationMethod = 3
    OAuthSettings        = local.portainer_oauth_settings
  } : null
  rancher_namespace_manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "cattle-system"
    }
  }
  rancher_certificate_manifests = local.rancher_enabled && local.tls_source == "ca_issuer" ? [
    {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "rancher-ingress-cert"
        namespace = "cattle-system"
      }
      spec = {
        secretName = local.rancher_tls_secret_name_value
        issuerRef = {
          name = "root-ca"
          kind = "ClusterIssuer"
        }
        dnsNames = [
          local.rancher_hostname_value,
        ]
      }
    },
  ] : []
  rancher_namespaced_kinds = toset([
    "ConfigMap",
    "Deployment",
    "Ingress",
    "Secret",
    "Service",
    "ServiceAccount",
  ])
  rancher_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/rancher.yaml", {
      rancher_hostname               = local.rancher_hostname_value
      rancher_replicas               = tostring(local.rancher_replicas_value)
      rancher_version                = tostring(local.rancher_version_value)
      rancher_debug                  = local.rancher_debug_value
      rancher_cpu_request            = local.rancher_cpu_request_value
      rancher_cpu_limit              = local.rancher_cpu_limit_value
      rancher_mem_request            = local.rancher_mem_request_value
      rancher_mem_limit              = local.rancher_mem_limit_value
      rancher_imperative_api_enabled = local.rancher_version_is_v214plus
    })) :
    merge(
      yamldecode(doc),
      contains(local.rancher_namespaced_kinds, try(yamldecode(doc).kind, "")) ? {
        metadata = merge(
          try(yamldecode(doc).metadata, {}),
          { namespace = "cattle-system" },
        )
      } : {}
    )
    if local.rancher_enabled && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  portainer_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/portainer.yaml", {
      portainer_hostname             = local.portainer_hostname
      portainer_image                = local.portainer_image_tag
      portainer_storage              = local.portainer_storage_class
      portainer_size                 = local.portainer_pvc_size
      portainer_tls_secret_name      = local.portainer_tls_secret_name
      portainer_admin_secret_name    = local.portainer_admin_secret_name_value
      portainer_oauth_ca_enabled     = local.portainer_auth_ca_enabled
      portainer_oauth_ca_secret_name = local.portainer_oauth_ca_secret_name_value
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]

  platform_resources = concat(
    slice(local.portainer_manifests, 0, var.skip_platform ? 0 : length(local.portainer_manifests)),
    [
      for m in [local.rancher_namespace_manifest] : m
      if !var.skip_platform && local.rancher_enabled
    ],
    [
      for m in local.rancher_manifests : m
      if !var.skip_platform
    ],
    [
      for m in local.rancher_certificate_manifests : m
      if !var.skip_platform
    ],
  )

  platform_certificates = [
    for m in local.platform_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  platform_ingress = [
    for m in local.platform_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  platform_other = [
    for m in local.platform_resources : m
    if !contains(["Certificate", "Ingress", "Namespace"], try(m.kind, ""))
  ]
  platform_namespaces = [
    for m in local.platform_resources : m
    if try(m.kind, "") == "Namespace"
  ]

  platform_tls_secrets = [
    for secret in local.tls_secrets : secret
    if local.rancher_enabled || format("%s/%s", secret.namespace, secret.secret_name) != format("cattle-system/%s", local.rancher_tls_secret_name_value)
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.platform_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" && !var.skip_platform ? [
    for target in concat(
      [for secret in local.platform_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)],
      local.rancher_enabled ? [format("cattle-system/%s", local.rancher_tls_secret_name_value)] : [],
    ) : target
  ] : []
  missing_preissued_tls_secret_targets = [
    for target in local.expected_preissued_tls_secret_targets : target
    if !contains(keys(local.preissued_tls_secrets_by_target), target)
  ]
  rancher_ca_content = local.rancher_enabled && local.rancher_private_ca_value ? try(file(local.root_ca_crt), "") : ""
  rancher_keycloakoidc_manifest = local.rancher_auth_enabled ? merge(
    {
      apiVersion          = "management.cattle.io/v3"
      kind                = "AuthConfig"
      type                = "keyCloakOIDCConfig"
      enabled             = true
      accessMode          = local.rancher_auth_access_mode_value
      allowedPrincipalIds = local.rancher_auth_allowed_principal_ids
      groupSearchEnabled  = true
      groupsField         = "groups"
      nameClaim           = "preferred_username"
      emailClaim          = "email"
      scopes              = "openid profile email"
      clientId            = local.rancher_oidc_client_id
      clientSecret        = local.rancher_oidc_client_secret
      issuer              = local.rancher_oidc_issuer
      authEndpoint        = local.rancher_oidc_auth_endpoint
      tokenEndpoint       = local.rancher_oidc_token_endpoint
      userinfoEndpoint    = local.rancher_oidc_userinfo_endpoint
      jwksUrl             = local.rancher_oidc_jwks_url
      endSessionEndpoint  = local.rancher_oidc_end_session_endpoint
      rancherUrl          = format("https://%s/verify-auth", local.rancher_hostname_value)
      metadata = {
        name = "keycloakoidc"
      }
    },
    trimspace(local.rancher_auth_ca_content) != "" ? {
      certificate = local.rancher_auth_ca_content
    } : {}
  ) : null
  rancher_auth_global_role_bindings = local.rancher_auth_enabled ? {
    for principal_id in local.rancher_auth_allowed_principal_ids : principal_id => {
      apiVersion = "management.cattle.io/v3"
      kind       = "GlobalRoleBinding"
      metadata = {
        name = format(
          "grb-keycloakoidc-%s-%s",
          replace(replace(trimprefix(principal_id, "keycloakoidc_group://"), "_", "-"), "/", "-"),
          local.rancher_auth_global_role_value
        )
        annotations = {
          "lifecycle.cattle.io/create.mgmt-auth-grb-controller" = "true"
        }
      }
      globalRoleName     = local.rancher_auth_global_role_value
      groupPrincipalName = principal_id
    }
  } : {}
  # Rancher version for patch compatibility (extract major.minor)
  rancher_version_major_minor = replace(
    substr(local.rancher_version_value, 0, regex("(\\d+\\.\\d+)", local.rancher_version_value) != null ? length(regex("(\\d+\\.\\d+)", local.rancher_version_value)) : 0),
    "/^v/",
    ""
  )

  # Check if Rancher version is 2.14 or later (for imperative API features)
  rancher_version_is_v214plus = (
    can(regex("^[3-9]\\.", local.rancher_version_major_minor)) ||
    can(regex("^2\\.(1[4-9]|[2-9][0-9])", local.rancher_version_major_minor))
  )

  # Define patch definitions for Rancher 2.12.x
  rancher_managed_resource_patches_v212 = {
    "cattle-provisioning-capi-system/capi-controller-manager" = {
      namespace = "cattle-provisioning-capi-system"
      resource  = "deployment"
      name      = "capi-controller-manager"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          template = {
            metadata = {
              labels = {
                "app.kubernetes.io/part-of" = "rancher"
              }
            }
            spec = {
              containers = [{
                name = "manager"
                resources = {
                  requests = {
                    cpu    = "25m"
                    memory = "64Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "64Mi"
                  }
                }
              }]
            }
          }
        }
      })
    }

    "cattle-fleet-system/fleet-controller" = {
      namespace = "cattle-fleet-system"
      resource  = "deployment"
      name      = "fleet-controller"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          template = {
            metadata = {
              labels = {
                "app.kubernetes.io/part-of" = "rancher"
              }
            }
            spec = {
              containers = [{
                name = "fleet-controller"
                resources = {
                  requests = {
                    cpu    = "25m"
                    memory = "64Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "64Mi"
                  }
                }
              }]
            }
          }
        }
      })
    }

    "cattle-fleet-system/fleet-cleanup-gitrepo-jobs" = {
      namespace = "cattle-fleet-system"
      resource  = "cronjob"
      name      = "fleet-cleanup-gitrepo-jobs"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          jobTemplate = {
            spec = {
              template = {
                metadata = {
                  labels = {
                    "app.kubernetes.io/part-of" = "rancher"
                  }
                }
                spec = {
                  containers = [{
                    name = "cleanup"
                    resources = {
                      requests = {
                        cpu    = "50m"
                        memory = "128Mi"
                      }
                      limits = {
                        cpu    = "200m"
                        memory = "128Mi"
                      }
                    }
                  }]
                }
              }
            }
          }
        }
      })
    }

    "cattle-fleet-system/gitjob" = {
      namespace = "cattle-fleet-system"
      resource  = "deployment"
      name      = "gitjob"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          template = {
            metadata = {
              labels = {
                "app.kubernetes.io/part-of" = "rancher"
              }
            }
            spec = {
              containers = [{
                name = "gitjob"
                resources = {
                  requests = {
                    cpu    = "25m"
                    memory = "64Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "64Mi"
                  }
                }
              }]
            }
          }
        }
      })
    }

    "cattle-fleet-system/helmops" = {
      namespace = "cattle-fleet-system"
      resource  = "deployment"
      name      = "helmops"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          template = {
            metadata = {
              labels = {
                "app.kubernetes.io/part-of" = "rancher"
              }
            }
            spec = {
              containers = [{
                name = "helmops"
                resources = {
                  requests = {
                    cpu    = "25m"
                    memory = "64Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "64Mi"
                  }
                }
              }]
            }
          }
        }
      })
    }

    "cattle-system/rancher-webhook" = {
      namespace = "cattle-system"
      resource  = "deployment"
      name      = "rancher-webhook"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          template = {
            metadata = {
              labels = {
                "app.kubernetes.io/part-of" = "rancher"
              }
            }
            spec = {
              containers = [{
                name = "rancher-webhook"
                resources = {
                  requests = {
                    cpu    = "25m"
                    memory = "128Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "128Mi"
                  }
                }
              }]
            }
          }
        }
      })
    }

    "fleet-default/rke2-machineconfig-cleanup-cronjob" = {
      namespace = "fleet-default"
      resource  = "cronjob"
      name      = "rke2-machineconfig-cleanup-cronjob"
      patch = jsonencode({
        metadata = {
          labels = {
            "app.kubernetes.io/part-of" = "rancher"
          }
        }
        spec = {
          jobTemplate = {
            spec = {
              template = {
                metadata = {
                  labels = {
                    "app.kubernetes.io/part-of" = "rancher"
                  }
                }
                spec = {
                  containers = [{
                    name = "rke2-machineconfig-cleanup-pod"
                    resources = {
                      requests = {
                        cpu    = "50m"
                        memory = "128Mi"
                      }
                      limits = {
                        cpu    = "200m"
                        memory = "128Mi"
                      }
                    }
                  }]
                }
              }
            }
          }
        }
      })
    }
  }

  # Define patch definitions for Rancher 2.14.x+ (includes turtles and additional fleet resources)
  rancher_managed_resource_patches_v214plus = merge(
    local.rancher_managed_resource_patches_v212,
    {
      "cattle-fleet-system/fleet-controller-multi" = {
        namespace = "cattle-fleet-system"
        resource  = "deployment"
        name      = "fleet-controller"
        patch = jsonencode({
          metadata = {
            labels = {
              "app.kubernetes.io/part-of" = "rancher"
            }
          }
          spec = {
            template = {
              metadata = {
                labels = {
                  "app.kubernetes.io/part-of" = "rancher"
                }
              }
              spec = {
                containers = [
                  {
                    name = "fleet-agentmanagement"
                    resources = {
                      requests = {
                        cpu    = "25m"
                        memory = "64Mi"
                      }
                      limits = {
                        cpu    = "200m"
                        memory = "64Mi"
                      }
                    }
                  },
                  {
                    name = "fleet-cleanup"
                    resources = {
                      requests = {
                        cpu    = "25m"
                        memory = "64Mi"
                      }
                      limits = {
                        cpu    = "200m"
                        memory = "64Mi"
                      }
                    }
                  },
                  {
                    name = "fleet-controller"
                    resources = {
                      requests = {
                        cpu    = "25m"
                        memory = "64Mi"
                      }
                      limits = {
                        cpu    = "200m"
                        memory = "64Mi"
                      }
                    }
                  },
                ]
              }
            }
          }
        })
      }
    }
  )

  # Select patch set based on Rancher version
  rancher_managed_resource_patches = (
    contains(["2.12", "2.13"], local.rancher_version_major_minor)
    ? local.rancher_managed_resource_patches_v212
    : local.rancher_managed_resource_patches_v214plus
  )
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

check "preissued_tls_secrets_unique" {
  assert {
    condition     = local.tls_source != "preissued" || length(local.platform_tls_secrets) == length(local.preissued_tls_secrets_by_target)
    error_message = "tls_secrets contains duplicate namespace/secret_name pairs."
  }
}

check "preissued_tls_secrets_required" {
  assert {
    condition     = local.tls_source != "preissued" || var.skip_platform || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || var.skip_platform || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued_tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

check "rancher_ca_file" {
  assert {
    condition     = !local.rancher_enabled || !local.rancher_private_ca_value || trimspace(local.rancher_ca_content) != ""
    error_message = "rancher_private_ca=true requires a readable, non-empty root_ca_crt file."
  }
}

check "rancher_auth_access_mode_valid" {
  assert {
    condition     = !local.rancher_auth_enabled || contains(["required", "restricted", "unrestricted"], local.rancher_auth_access_mode_value)
    error_message = "rancher_auth_access_mode must be required, restricted, or unrestricted."
  }
}

check "rancher_auth_identity_outputs" {
  assert {
    condition = !local.rancher_auth_enabled || (
      contains(local.available_identity_realms, local.rancher_auth_keycloak_realm_value) &&
      trimspace(local.rancher_oidc_issuer) != "" &&
      trimspace(local.rancher_oidc_client_id) != "" &&
      trimspace(local.rancher_oidc_client_secret) != ""
    )
    error_message = format("Rancher auth automation requires identity state with realm %q and a confidential rancher OIDC client. Available realms: %s", local.rancher_auth_keycloak_realm_value, join(", ", local.available_identity_realms))
  }
}

check "portainer_auth_identity_outputs" {
  assert {
    condition = !local.portainer_auth_enabled || (
      contains(local.available_identity_realms, local.portainer_auth_keycloak_realm_value) &&
      trimspace(local.portainer_oidc_issuer) != "" &&
      trimspace(local.portainer_oidc_client_id) != "" &&
      trimspace(local.portainer_oidc_client_secret) != ""
    )
    error_message = format("Portainer auth automation requires identity state with realm %q and a confidential portainer OIDC client. Available realms: %s", local.portainer_auth_keycloak_realm_value, join(", ", local.available_identity_realms))
  }
}

check "platform_credentials" {
  assert {
    condition = var.skip_platform || (
      trimspace(local.platform_portainer_admin_password) != "" &&
      (!local.rancher_enabled || trimspace(local.platform_rancher_bootstrap_password) != "")
    )
    error_message = "credentials.json must define platform.portainer_admin_password and platform.rancher_bootstrap_password when Rancher is enabled."
  }
}

resource "kubernetes_manifest" "platform_namespaces" {
  for_each = { for i, m in local.platform_namespaces : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "platform_other" {
  for_each = { for i, m in local.platform_other : i => m }
  manifest = each.value
  computed_fields = concat(
    [
      "globalDefault",
      "metadata.annotations",
      "metadata.annotations[\"deprecated.daemonset.template.generation\"]",
      "spec.template.spec.containers[0].resources.limits.cpu",
      "spec.template.spec.nodeSelector",
    ],
    try(each.value.kind, "") == "Deployment" && try(each.value.metadata.name, "") == "rancher" ? [
      "object.metadata.annotations",
      "object.metadata.annotations[\"deployment.kubernetes.io/revision\"]",
      "object.metadata.annotations[\"field.cattle.io/publicEndpoints\"]",
    ] : [],
  )
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
      object.metadata.annotations,
      object.metadata.annotations["deployment.kubernetes.io/revision"],
      object.metadata.annotations["field.cattle.io/publicEndpoints"],
    ]
  }
  depends_on = [
    kubernetes_manifest.platform_namespaces,
    kubernetes_secret_v1.portainer_admin,
    kubernetes_secret_v1.portainer_oauth_ca,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source == "preissued" && !var.skip_platform ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type       = "kubernetes.io/tls"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "kubernetes_secret_v1" "portainer_admin" {
  count = !var.skip_platform ? 1 : 0

  metadata {
    name      = local.portainer_admin_secret_name_value
    namespace = "portainer"
  }

  data = {
    password = local.platform_portainer_admin_password
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "kubernetes_secret_v1" "portainer_oauth_ca" {
  count = local.portainer_auth_ca_enabled ? 1 : 0

  metadata {
    name      = local.portainer_oauth_ca_secret_name_value
    namespace = "portainer"
  }

  data = {
    "ca.crt" = local.portainer_auth_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "kubernetes_secret_v1" "rancher_ca" {
  count = !var.skip_platform && local.rancher_enabled && local.rancher_private_ca_value ? 1 : 0

  metadata {
    name      = "tls-ca"
    namespace = "cattle-system"
  }

  data = {
    "cacerts.pem" = local.rancher_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "null_resource" "rancher_ready" {
  count = local.rancher_auth_enabled ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cattle-system rollout status deploy/rancher --timeout=900s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cattle-system wait --for=condition=Available deploy/rancher --timeout=900s"
  }

  depends_on = [
    kubernetes_manifest.platform_other,
    kubernetes_manifest.platform_ingress,
    kubernetes_secret_v1.rancher_ca,
  ]
}

resource "local_sensitive_file" "rancher_keycloakoidc_authconfig" {
  count = local.rancher_auth_enabled ? 1 : 0

  filename   = "${path.module}/.generated-rancher-keycloakoidc-authconfig.yaml"
  content    = yamlencode(local.rancher_keycloakoidc_manifest)
  depends_on = [null_resource.rancher_ready]
}

resource "null_resource" "rancher_keycloakoidc_authconfig" {
  count = local.rancher_auth_enabled ? 1 : 0

  triggers = {
    manifest_sha = sha256(yamlencode(local.rancher_keycloakoidc_manifest))
  }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_sensitive_file.rancher_keycloakoidc_authconfig[0].filename}"
  }

  depends_on = [local_sensitive_file.rancher_keycloakoidc_authconfig]
}

resource "local_file" "rancher_auth_global_role_bindings" {
  for_each = local.rancher_auth_global_role_bindings

  filename   = format("%s/.generated-rancher-grb-%s.yaml", path.module, replace(replace(trimprefix(each.key, "keycloakoidc_group://"), "/", "-"), "_", "-"))
  content    = yamlencode(each.value)
  depends_on = [null_resource.rancher_keycloakoidc_authconfig]
}

resource "null_resource" "rancher_auth_global_role_bindings" {
  for_each = local.rancher_auth_global_role_bindings

  triggers = {
    manifest_sha = sha256(yamlencode(each.value))
  }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_file.rancher_auth_global_role_bindings[each.key].filename}"
  }

  depends_on = [local_file.rancher_auth_global_role_bindings]
}

resource "null_resource" "rancher_managed_resource_patches" {
  for_each = !var.skip_platform && local.rancher_enabled ? local.rancher_managed_resource_patches : {}

  triggers = {
    patch_sha = sha256(each.value.patch)
  }

  provisioner "local-exec" {
    command = "for i in $(seq 1 60); do KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ${each.value.namespace} get ${each.value.resource} ${each.value.name} >/dev/null 2>&1 && break; if [ \"$i\" -eq 60 ]; then KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ${each.value.namespace} get ${each.value.resource} ${each.value.name}; exit 1; fi; sleep 10; done; KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ${each.value.namespace} patch ${each.value.resource} ${each.value.name} --type=strategic --patch '${each.value.patch}'"
  }

  depends_on = [
    null_resource.rancher_ready,
    null_resource.rancher_keycloakoidc_authconfig,
  ]
}

resource "local_sensitive_file" "portainer_oauth_configure" {
  count = local.portainer_auth_enabled ? 1 : 0

  filename        = "${path.module}/.generated-portainer-oauth-configure.sh"
  file_permission = "0700"
  content = templatefile("${path.module}/configure-portainer-oauth.sh.tftpl", {
    kubeconfig_path                       = abspath("${path.module}/${var.kubeconfig_path}")
    portainer_auth_body                   = jsonencode({ username = "admin", password = local.platform_portainer_admin_password })
    portainer_oauth_payload               = jsonencode(local.portainer_oauth_payload)
    portainer_default_team_name_json      = jsonencode(local.portainer_auth_default_team_name_value)
    portainer_default_team_role_id_string = tostring(local.portainer_auth_default_team_role_id_value)
    portainer_default_team_existing_users = jsonencode(local.portainer_auth_default_team_existing_users_value)
  })
  depends_on = [kubernetes_manifest.platform_ingress]
}

resource "null_resource" "portainer_oauth_configure" {
  count = local.portainer_auth_enabled ? 1 : 0

  triggers = {
    script_sha = nonsensitive(sha256(local_sensitive_file.portainer_oauth_configure[0].content))
  }

  provisioner "local-exec" {
    command = local_sensitive_file.portainer_oauth_configure[0].filename
  }

  depends_on = [
    local_sensitive_file.portainer_oauth_configure,
  ]
}

resource "kubernetes_secret_v1" "rancher_bootstrap" {
  count = !var.skip_platform && local.rancher_enabled ? 1 : 0

  metadata {
    name      = "bootstrap-secret"
    namespace = "cattle-system"
  }

  data = {
    bootstrapPassword = local.platform_rancher_bootstrap_password
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "kubernetes_manifest" "platform_certificates" {
  for_each = { for i, m in local.platform_certificates : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.platform_namespaces,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "platform_ingress" {
  for_each = { for i, m in local.platform_ingress : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.platform_other,
    kubernetes_manifest.platform_certificates,
    kubernetes_secret_v1.preissued_tls,
    kubernetes_secret_v1.rancher_bootstrap,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "rancher_enabled" {
  value = local.rancher_enabled && !var.skip_platform
}

output "portainer_url" {
  value = var.skip_platform ? null : "https://${local.portainer_hostname}"
}

output "portainer_admin_password" {
  value     = var.skip_platform ? null : local.platform_portainer_admin_password
  sensitive = true
}

output "portainer_auth_enabled" {
  value = local.portainer_auth_enabled
}

output "rancher_url" {
  value = local.rancher_enabled && !var.skip_platform ? "https://${local.rancher_hostname_value}" : null
}

output "rancher_bootstrap_password" {
  value     = local.rancher_enabled && !var.skip_platform ? local.platform_rancher_bootstrap_password : null
  sensitive = true
}
