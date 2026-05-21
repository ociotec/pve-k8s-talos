terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4, < 3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.8.1"
    }
  }
}

variable "cluster_name" {
  type        = string
  description = "Cluster name, used as the default S3 region."
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

variable "vms" {
  type = map(object({
    node_name  = string
    vm_id      = number
    type       = string
    ip         = string
    k8s_labels = optional(map(string), {})
    vm_tags    = optional(string)
  }))
}

variable "resources" {
  type = map(object({
    vcpus      = number
    memory     = number
    k8s_node   = string
    k8s_labels = optional(map(string), {})
    disks = list(object({
      size  = number
      mount = optional(string)
    }))
  }))
}

data "terraform_remote_state" "identity" {
  count = local.garage_console_auth_enabled ? 1 : 0

  backend = "local"
  config = {
    path = abspath("${path.root}/../identity/terraform.tfstate")
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  s3_namespace_value          = try(local.s3_namespace, "s3")
  garage_name_value           = try(local.garage_name, "garage")
  garage_node_label_value     = try(local.garage_node_k8s_label, "s3")
  garage_data_host_path_value = try(local.garage_data_host_path, "/var/lib/s3")
  garage_storage_class_value  = try(local.garage_storage_class_name, "s3-local")
  garage_image_value          = try(local.garage_image, "dxflrs/garage:v2.2.0")
  garage_console_image_value  = try(local.garage_console_image, "khairul169/garage-webui:1.1.0")

  garage_s3_hostname_value                 = try(local.garage_s3_hostname, "s3.${local.domain}")
  garage_console_hostname_value            = try(local.garage_console_hostname, "s3-console.${local.domain}")
  garage_s3_tls_secret_name_value          = try(local.garage_s3_tls_secret_name, "s3-api-tls")
  garage_console_tls_secret_name_value     = try(local.garage_console_tls_secret_name, "s3-console-tls")
  garage_replication_factor_value          = try(local.garage_replication_factor, 3)
  garage_s3_region_value                   = var.cluster_name
  garage_cpu_request_value                 = try(local.garage_cpu_request, "500m")
  garage_cpu_limit_value                   = try(local.garage_cpu_limit, "1")
  garage_mem_request_value                 = try(local.garage_mem_request, "1Gi")
  garage_mem_limit_value                   = try(local.garage_mem_limit, "1Gi")
  garage_console_cpu_request_value         = try(local.garage_console_cpu_request, "100m")
  garage_console_cpu_limit_value           = try(local.garage_console_cpu_limit, "500m")
  garage_console_mem_request_value         = try(local.garage_console_mem_request, "256Mi")
  garage_console_mem_limit_value           = try(local.garage_console_mem_limit, "256Mi")
  garage_oauth2_proxy_image_tag_value      = try(local.garage_oauth2_proxy_image_tag, "v7.15.2")
  garage_oauth2_proxy_cpu_request_value    = try(local.garage_oauth2_proxy_cpu_request, "50m")
  garage_oauth2_proxy_cpu_limit_value      = try(local.garage_oauth2_proxy_cpu_limit, "200m")
  garage_oauth2_proxy_mem_request_value    = try(local.garage_oauth2_proxy_mem_request, "128Mi")
  garage_oauth2_proxy_mem_limit_value      = try(local.garage_oauth2_proxy_mem_limit, "128Mi")
  garage_console_auth_realm_value          = trimspace(try(local.garage_console_auth_keycloak_realm, ""))
  garage_console_auth_enabled              = local.garage_console_auth_realm_value != ""
  garage_console_auth_allowed_groups_value = distinct(compact(try(local.garage_console_auth_allowed_groups, ["k8s-admins"])))
  garage_console_oauth_client_id           = "garage-console"
  garage_console_oauth_secret_name_value   = "garage-console-oauth"
  garage_console_auth_ca_secret_name_value = "garage-console-oauth-ca"
  garage_console_oauth_cookie_name_value   = "_garage_console_oauth2_proxy"
  garage_console_oauth_redirect_uri        = format("https://%s/oauth2/callback", local.garage_console_hostname_value)
  garage_console_oauth_post_logout_uri     = format("https://%s/", local.garage_console_hostname_value)
  garage_console_auth_ca_content           = local.garage_console_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  garage_console_auth_ca_enabled           = trimspace(local.garage_console_auth_ca_content) != ""
  tls_source_value                         = try(local.tls_source, "ca_issuer")

  effective_vm_labels = {
    for name, vm in var.vms :
    name => merge(try(var.resources[vm.type].k8s_labels, {}), try(vm.k8s_labels, {}))
  }
  garage_vm_names = sort([
    for name, vm in var.vms : name
    if try(local.effective_vm_labels[name][local.garage_node_label_value], "") == "true"
  ])
  garage_vms_by_id = {
    for index, name in local.garage_vm_names : tostring(index) => merge(var.vms[name], {
      name      = name
      garage_id = index
    })
  }
  garage_replicas_value = length(local.garage_vms_by_id)
  garage_data_disks_by_id = {
    for garage_id, node in local.garage_vms_by_id :
    garage_id => [
      for disk in var.resources[node.type].disks : disk
      if try(disk.mount, "") == local.garage_data_host_path_value
    ]
  }
  garage_data_disk_capacity_by_id = {
    for garage_id, disks in local.garage_data_disks_by_id :
    garage_id => format("%dGi", disks[0].size)
    if length(disks) == 1
  }
  garage_layout_capacity_by_id = {
    for garage_id, disks in local.garage_data_disks_by_id :
    garage_id => format("%dG", disks[0].size)
    if length(disks) == 1
  }
  garage_data_disk_sizes = [
    for _, disks in local.garage_data_disks_by_id : disks[0].size
    if length(disks) == 1
  ]

  api_service_name     = "api"
  admin_service_name   = "admin"
  console_service_name = "console"
  garage_internal_s3_endpoint_url = format(
    "http://%s.%s.svc.cluster.local:3900",
    local.api_service_name,
    local.s3_namespace_value,
  )
  garage_internal_admin_endpoint_url = format(
    "http://%s.%s.svc.cluster.local:3903",
    local.admin_service_name,
    local.s3_namespace_value,
  )

  garage_config_toml = <<-EOT
  metadata_dir = "/var/lib/garage/meta"
  data_dir = "/var/lib/garage/data"
  metadata_snapshots_dir = "/var/lib/garage/snapshots"
  db_engine = "lmdb"
  metadata_auto_snapshot_interval = "6h"
  replication_factor = ${local.garage_replication_factor_value}
  compression_level = 2
  rpc_bind_addr = "0.0.0.0:3901"

  [kubernetes_discovery]
  namespace = "${local.s3_namespace_value}"
  service_name = "${local.garage_name_value}"
  skip_crd = true

  [s3_api]
  api_bind_addr = "0.0.0.0:3900"
  s3_region = "${local.garage_s3_region_value}"
  root_domain = ".${local.garage_s3_hostname_value}"

  [admin]
  api_bind_addr = "0.0.0.0:3903"
  metrics_require_token = false
  EOT

  garage_certificate_manifests = local.tls_source_value == "ca_issuer" ? {
    api = {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "s3-api-ingress-cert"
        namespace = local.s3_namespace_value
      }
      spec = {
        secretName = local.garage_s3_tls_secret_name_value
        issuerRef = {
          name = "root-ca"
          kind = "ClusterIssuer"
        }
        dnsNames = [local.garage_s3_hostname_value]
      }
    }
    console = {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "s3-console-ingress-cert"
        namespace = local.s3_namespace_value
      }
      spec = {
        secretName = local.garage_console_tls_secret_name_value
        issuerRef = {
          name = "root-ca"
          kind = "ClusterIssuer"
        }
        dnsNames = [local.garage_console_hostname_value]
      }
    }
  } : {}
  garage_tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = local.s3_namespace_value
      secret_name = local.garage_s3_tls_secret_name_value
    },
    {
      certificate = local.default_certificate_name
      namespace   = local.s3_namespace_value
      secret_name = local.garage_console_tls_secret_name_value
    },
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.garage_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }

  identity_realm_groups = local.garage_console_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_realm_groups,
    {}
  ) : {}
  identity_oidc_metadata = local.garage_console_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_metadata,
    {}
  ) : {}
  identity_oidc_secrets = local.garage_console_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_secrets,
    {}
  ) : {}
  available_identity_realms = keys(local.identity_oidc_metadata)
  garage_console_oidc_issuer = local.garage_console_auth_enabled ? try(
    local.identity_oidc_metadata[local.garage_console_auth_realm_value].issuer_url,
    ""
  ) : ""
  garage_console_oidc_client_id = local.garage_console_auth_enabled ? try(
    local.identity_oidc_metadata[local.garage_console_auth_realm_value].clients[local.garage_console_oauth_client_id].client_id,
    ""
  ) : ""
  garage_console_oidc_client_secret = local.garage_console_auth_enabled ? try(
    local.identity_oidc_secrets[local.garage_console_auth_realm_value][local.garage_console_oauth_client_id],
    ""
  ) : ""
  garage_console_oidc_end_session_url = local.garage_console_oidc_issuer != "" ? format("%s/protocol/openid-connect/logout", local.garage_console_oidc_issuer) : ""
  garage_console_oauth_backend_logout_url = local.garage_console_oidc_end_session_url != "" ? format(
    "%s?client_id=%s&id_token_hint={id_token}&post_logout_redirect_uri=%s",
    local.garage_console_oidc_end_session_url,
    urlencode(local.garage_console_oauth_client_id),
    urlencode(local.garage_console_oauth_post_logout_uri)
  ) : ""
  garage_console_auth_effective_allowed_groups = distinct(compact(concat(
    local.garage_console_auth_allowed_groups_value,
    flatten([
      for group_name in local.garage_console_auth_allowed_groups_value : [
        for ldap_group in try(local.identity_realm_groups[local.garage_console_auth_realm_value][group_name].included_ldap_groups, []) : ldap_group.group_name
      ]
    ])
  )))
  missing_garage_console_auth_group_definitions = local.garage_console_auth_enabled ? [
    for group_name in local.garage_console_auth_allowed_groups_value : group_name
    if !contains(keys(try(local.identity_realm_groups[local.garage_console_auth_realm_value], {})), group_name)
  ] : []
}

check "garage_node_count" {
  assert {
    condition     = local.garage_replicas_value >= 3
    error_message = format("At least 3 Garage nodes are required; found %d VMs with effective k8s label %s = \"true\".", local.garage_replicas_value, local.garage_node_label_value)
  }
}

check "garage_data_disks" {
  assert {
    condition = alltrue([
      for _, disks in local.garage_data_disks_by_id : length(disks) == 1
    ])
    error_message = format("Each Garage VM type must define exactly one resources disk mounted at %s.", local.garage_data_host_path_value)
  }
}

check "garage_data_disk_sizes" {
  assert {
    condition     = length(local.garage_data_disk_sizes) == local.garage_replicas_value && length(distinct(local.garage_data_disk_sizes)) == 1
    error_message = "All Garage data disks must have the same size in v1."
  }
}

check "garage_replication_factor" {
  assert {
    condition     = local.garage_replication_factor_value >= 1 && local.garage_replication_factor_value <= local.garage_replicas_value
    error_message = format("garage_replication_factor must be between 1 and Garage node count (%d).", local.garage_replicas_value)
  }
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source_value)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source_value)
  }
}

check "preissued_tls_secret_files" {
  assert {
    condition = local.tls_source_value != "preissued" || alltrue([
      for _, secret in local.preissued_tls_secrets_by_target :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "default_certificate_name must reference readable certificate/key files in available_certificates for S3 ingresses."
  }
}

check "garage_console_auth_identity_client" {
  assert {
    condition = !local.garage_console_auth_enabled || (
      contains(local.available_identity_realms, local.garage_console_auth_realm_value) &&
      trimspace(local.garage_console_oidc_issuer) != "" &&
      trimspace(local.garage_console_oidc_client_id) != "" &&
      trimspace(local.garage_console_oidc_client_secret) != ""
    )
    error_message = format("Garage Console Keycloak auth is enabled for realm %q, but identity state does not expose that realm with a confidential garage-console OIDC client. Available realms: %s", local.garage_console_auth_realm_value, join(", ", local.available_identity_realms))
  }
}

check "garage_console_auth_groups" {
  assert {
    condition     = !local.garage_console_auth_enabled || (length(local.garage_console_auth_effective_allowed_groups) > 0 && length(local.missing_garage_console_auth_group_definitions) == 0)
    error_message = format("Garage Console auth groups must exist in the selected Keycloak realm. Missing logical groups: %s", join(", ", local.missing_garage_console_auth_group_definitions))
  }
}

resource "random_id" "garage_rpc_secret" {
  byte_length = 32
}

resource "random_password" "garage_admin_token" {
  length  = 48
  special = false
}

resource "random_password" "garage_metrics_token" {
  length  = 48
  special = false
}

resource "random_password" "garage_console_oauth_cookie_secret" {
  count   = local.garage_console_auth_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_manifest" "namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.s3_namespace_value
      labels = {
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/audit"   = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      }
    }
  }
}

resource "kubernetes_manifest" "garage_node_crd" {
  manifest = {
    apiVersion = "apiextensions.k8s.io/v1"
    kind       = "CustomResourceDefinition"
    metadata = {
      name = "garagenodes.deuxfleurs.fr"
    }
    spec = {
      conversion = {
        strategy = "None"
      }
      group = "deuxfleurs.fr"
      names = {
        kind     = "GarageNode"
        listKind = "GarageNodeList"
        plural   = "garagenodes"
        singular = "garagenode"
      }
      scope = "Namespaced"
      versions = [
        {
          name = "v1"
          schema = {
            openAPIV3Schema = {
              description = "Auto-generated derived type for Node via `CustomResource`"
              properties = {
                spec = {
                  properties = {
                    address = {
                      format = "ip"
                      type   = "string"
                    }
                    hostname = {
                      type = "string"
                    }
                    port = {
                      format  = "uint16"
                      minimum = 0
                      type    = "integer"
                    }
                  }
                  required = ["address", "hostname", "port"]
                  type     = "object"
                }
              }
              required = ["spec"]
              title    = "GarageNode"
              type     = "object"
            }
          }
          served       = true
          storage      = true
          subresources = {}
        },
      ]
    }
  }
}

resource "kubernetes_secret_v1" "garage_secrets" {
  metadata {
    name      = "garage-secrets"
    namespace = local.s3_namespace_value
  }

  data = {
    "rpc-secret"    = random_id.garage_rpc_secret.hex
    "admin-token"   = random_password.garage_admin_token.result
    "metrics-token" = random_password.garage_metrics_token.result
  }

  type = "Opaque"

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "config" {
  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "garage-config"
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    data = {
      "garage.toml" = local.garage_config_toml
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "storage_class" {
  manifest = {
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = local.garage_storage_class_value
    }
    provisioner          = "kubernetes.io/no-provisioner"
    volumeBindingMode    = "WaitForFirstConsumer"
    reclaimPolicy        = "Retain"
    allowVolumeExpansion = false
  }
}

resource "kubernetes_manifest" "pv" {
  for_each = local.garage_vms_by_id

  manifest = {
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata = {
      name = format("s3-data-%s", each.key)
      labels = {
        app                             = local.garage_name_value
        "app.kubernetes.io/part-of"     = "garage"
        (local.garage_node_label_value) = "true"
        "s3.garage/node-id"             = each.key
      }
    }
    spec = {
      capacity = {
        storage = local.garage_data_disk_capacity_by_id[each.key]
      }
      accessModes                   = ["ReadWriteOnce"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = local.garage_storage_class_value
      volumeMode                    = "Filesystem"
      local = {
        path = local.garage_data_host_path_value
      }
      claimRef = {
        namespace = local.s3_namespace_value
        name      = format("data-%s-%s", local.garage_name_value, each.key)
      }
      nodeAffinity = {
        required = {
          nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = [each.value.name]
                },
              ]
            },
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.storage_class,
  ]
}

resource "kubernetes_manifest" "service_account" {
  manifest = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = local.garage_name_value
      namespace = local.s3_namespace_value
    }
    automountServiceAccountToken = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "garage_discovery_role" {
  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "${local.garage_name_value}-discovery"
      namespace = local.s3_namespace_value
    }
    rules = [
      {
        apiGroups = ["deuxfleurs.fr"]
        resources = ["garagenodes"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
    ]
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.garage_node_crd,
  ]
}

resource "kubernetes_manifest" "garage_discovery_role_binding" {
  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "${local.garage_name_value}-discovery"
      namespace = local.s3_namespace_value
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = local.garage_name_value
        namespace = local.s3_namespace_value
      },
    ]
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "${local.garage_name_value}-discovery"
    }
  }

  depends_on = [
    kubernetes_manifest.garage_discovery_role,
    kubernetes_manifest.service_account,
  ]
}

resource "kubernetes_manifest" "headless_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.garage_name_value
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      clusterIP                = "None"
      publishNotReadyAddresses = true
      selector = {
        app = local.garage_name_value
      }
      ports = [
        { name = "s3", port = 3900, targetPort = 3900 },
        { name = "rpc", port = 3901, targetPort = 3901 },
        { name = "admin", port = 3903, targetPort = 3903 },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "api_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.api_service_name
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      selector = {
        app = local.garage_name_value
      }
      ports = [
        { name = "http", port = 3900, targetPort = 3900 },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "admin_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.admin_service_name
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      selector = {
        app = local.garage_name_value
      }
      ports = [
        { name = "http", port = 3903, targetPort = 3903 },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "statefulset" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata = {
      name      = local.garage_name_value
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      serviceName         = local.garage_name_value
      replicas            = local.garage_replicas_value
      podManagementPolicy = "Parallel"
      selector = {
        matchLabels = {
          app = local.garage_name_value
        }
      }
      template = {
        metadata = {
          labels = {
            app                         = local.garage_name_value
            "app.kubernetes.io/part-of" = "garage"
          }
          annotations = {
            "checksum/garage-config" = sha256(local.garage_config_toml)
            "prometheus.io/scrape"   = "true"
            "prometheus.io/port"     = "3903"
            "prometheus.io/path"     = "/metrics"
          }
        }
        spec = {
          serviceAccountName            = local.garage_name_value
          automountServiceAccountToken  = true
          terminationGracePeriodSeconds = 60
          priorityClassName             = "infra-critical"
          securityContext = {
            fsGroup             = 1000
            fsGroupChangePolicy = "OnRootMismatch"
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      app = local.garage_name_value
                    }
                  }
                  topologyKey = "kubernetes.io/hostname"
                },
              ]
            }
          }
          containers = [
            {
              name            = "garage"
              image           = local.garage_image_value
              imagePullPolicy = "IfNotPresent"
              env = [
                {
                  name = "POD_NAME"
                  valueFrom = {
                    fieldRef = {
                      fieldPath = "metadata.name"
                    }
                  }
                },
                {
                  name = "GARAGE_RPC_SECRET"
                  valueFrom = {
                    secretKeyRef = {
                      name = "garage-secrets"
                      key  = "rpc-secret"
                    }
                  }
                },
                {
                  name = "GARAGE_ADMIN_TOKEN"
                  valueFrom = {
                    secretKeyRef = {
                      name = "garage-secrets"
                      key  = "admin-token"
                    }
                  }
                },
              ]
              ports = [
                { name = "s3", containerPort = 3900 },
                { name = "rpc", containerPort = 3901 },
                { name = "admin", containerPort = 3903 },
              ]
              resources = {
                requests = {
                  cpu    = local.garage_cpu_request_value
                  memory = local.garage_mem_request_value
                }
                limits = {
                  cpu    = local.garage_cpu_limit_value
                  memory = local.garage_mem_limit_value
                }
              }
              startupProbe = {
                tcpSocket = {
                  port = 3901
                }
                periodSeconds    = 10
                timeoutSeconds   = 1
                successThreshold = 1
                failureThreshold = 60
              }
              readinessProbe = {
                tcpSocket = {
                  port = 3901
                }
                initialDelaySeconds = 5
                periodSeconds       = 10
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              livenessProbe = {
                tcpSocket = {
                  port = 3901
                }
                initialDelaySeconds = 30
                periodSeconds       = 20
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = true
                runAsNonRoot             = true
                runAsUser                = 1000
                runAsGroup               = 1000
                capabilities = {
                  drop = ["ALL"]
                }
              }
              volumeMounts = [
                {
                  name      = "config"
                  mountPath = "/etc/garage.toml"
                  subPath   = "garage.toml"
                  readOnly  = true
                },
                {
                  name      = "data"
                  mountPath = "/var/lib/garage"
                },
              ]
            },
          ]
          volumes = [
            {
              name = "config"
              configMap = {
                name = "garage-config"
              }
            },
          ]
        }
      }
      volumeClaimTemplates = [
        {
          metadata = {
            name = "data"
          }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = local.garage_storage_class_value
            resources = {
              requests = {
                storage = format("%dGi", local.garage_data_disk_sizes[0])
              }
            }
          }
        },
      ]
    }
  }

  computed_fields = [
    "spec.volumeClaimTemplates[0].metadata.creationTimestamp",
  ]

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.service_account,
    kubernetes_manifest.config,
    kubernetes_secret_v1.garage_secrets,
    kubernetes_manifest.garage_node_crd,
    kubernetes_manifest.garage_discovery_role_binding,
    kubernetes_manifest.storage_class,
    kubernetes_manifest.pv,
    kubernetes_manifest.headless_service,
  ]
}

resource "kubernetes_manifest" "pdb" {
  manifest = {
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = local.garage_name_value
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.garage_name_value
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      minAvailable = max(1, local.garage_replication_factor_value - 1)
      selector = {
        matchLabels = {
          app = local.garage_name_value
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.statefulset,
  ]
}

resource "null_resource" "garage_layout" {
  triggers = {
    namespace       = local.s3_namespace_value
    name            = local.garage_name_value
    replicas        = tostring(local.garage_replicas_value)
    capacities      = jsonencode(local.garage_layout_capacity_by_id)
    kubeconfig_path = abspath("${path.module}/${var.kubeconfig_path}")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${self.triggers.kubeconfig_path}"
      ns="${self.triggers.namespace}"
      name="${self.triggers.name}"
      replicas="${self.triggers.replicas}"
      capacities='${self.triggers.capacities}'

      kubectl -n "$ns" rollout status statefulset/"$name" --timeout=900s

      node_refs=()
      for ((i = 0; i < replicas; i++)); do
        pod="$name-$i"
        until kubectl -n "$ns" exec "$pod" -- /garage -c /etc/garage.toml status >/dev/null 2>&1; do
          sleep 5
        done
        node_id="$(kubectl -n "$ns" exec "$pod" -- /garage -c /etc/garage.toml node id | awk '{ print $NF }')"
        node_refs[$i]="$${node_id%%@*}@$pod.$name.$ns.svc.cluster.local:3901"
      done

      for ((i = 1; i < replicas; i++)); do
        kubectl -n "$ns" exec "$name-0" -- /garage -c /etc/garage.toml node connect "$${node_refs[$i]}" >/dev/null || true
      done

      for _ in $(seq 1 60); do
        connected="$(kubectl -n "$ns" exec "$name-0" -- /garage -c /etc/garage.toml status | grep -E '^[[:space:]]*[0-9a-f]{16,}' | wc -l | tr -d ' ')"
        if [[ "$connected" == "$replicas" ]]; then
          break
        fi
        sleep 5
      done

      status="$(kubectl -n "$ns" exec "$name-0" -- /garage -c /etc/garage.toml status)"
      if ! grep -q "NO ROLE" <<< "$status"; then
        exit 0
      fi

      for ((i = 0; i < replicas; i++)); do
        node_id="$${node_refs[$i]%%@*}"
        capacity="$(jq -r --arg id "$i" '.[$id]' <<< "$capacities")"
        kubectl -n "$ns" exec "$name-0" -- /garage -c /etc/garage.toml layout assign "$node_id" -z "$name-$i" -c "$capacity" -t "$name-$i"
      done
      kubectl -n "$ns" exec "$name-0" -- /garage -c /etc/garage.toml layout apply --version 1
    EOT
  }

  depends_on = [
    kubernetes_manifest.statefulset,
  ]
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source_value == "preissued" ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type = "kubernetes.io/tls"

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = local.tls_source_value == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_manifest" "certificate" {
  for_each = local.garage_certificate_manifests
  manifest = each.value

  depends_on = [
    kubernetes_manifest.namespace,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "kubernetes_manifest" "api_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "s3-api"
      namespace = local.s3_namespace_value
      annotations = {
        "nginx.ingress.kubernetes.io/proxy-body-size" = "0"
      }
    }
    spec = {
      ingressClassName = "nginx"
      tls = [
        {
          hosts      = [local.garage_s3_hostname_value]
          secretName = local.garage_s3_tls_secret_name_value
        },
      ]
      rules = [
        {
          host = local.garage_s3_hostname_value
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = local.api_service_name
                    port = {
                      number = 3900
                    }
                  }
                }
              },
            ]
          }
        },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.api_service,
    kubernetes_manifest.certificate,
    kubernetes_secret_v1.preissued_tls,
  ]
}

resource "kubernetes_secret_v1" "console_oauth" {
  count = local.garage_console_auth_enabled ? 1 : 0

  metadata {
    name      = local.garage_console_oauth_secret_name_value
    namespace = local.s3_namespace_value
  }

  data = {
    "client-secret" = local.garage_console_oidc_client_secret
    "cookie-secret" = random_password.garage_console_oauth_cookie_secret[0].result
  }

  type = "Opaque"

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_secret_v1" "console_oauth_ca" {
  count = local.garage_console_auth_ca_enabled ? 1 : 0

  metadata {
    name      = local.garage_console_auth_ca_secret_name_value
    namespace = local.s3_namespace_value
  }

  data = {
    "ca.crt" = local.garage_console_auth_ca_content
  }

  type = "Opaque"

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "console_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.console_service_name
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.console_service_name
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = local.console_service_name
        }
      }
      template = {
        metadata = {
          labels = {
            app                         = local.console_service_name
            "app.kubernetes.io/part-of" = "garage"
          }
        }
        spec = {
          automountServiceAccountToken = false
          priorityClassName            = "infra-observability"
          securityContext = {
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          containers = [
            {
              name            = "console"
              image           = local.garage_console_image_value
              imagePullPolicy = "IfNotPresent"
              env = [
                { name = "API_BASE_URL", value = local.garage_internal_admin_endpoint_url },
                { name = "S3_ENDPOINT_URL", value = local.garage_internal_s3_endpoint_url },
                { name = "S3_REGION", value = local.garage_s3_region_value },
                {
                  name = "API_ADMIN_KEY"
                  valueFrom = {
                    secretKeyRef = {
                      name = "garage-secrets"
                      key  = "admin-token"
                    }
                  }
                },
              ]
              ports = [
                { name = "http", containerPort = 3909 },
              ]
              resources = {
                requests = {
                  cpu    = local.garage_console_cpu_request_value
                  memory = local.garage_console_mem_request_value
                }
                limits = {
                  cpu    = local.garage_console_cpu_limit_value
                  memory = local.garage_console_mem_limit_value
                }
              }
              startupProbe = {
                tcpSocket = {
                  port = 3909
                }
                periodSeconds    = 5
                timeoutSeconds   = 1
                successThreshold = 1
                failureThreshold = 30
              }
              readinessProbe = {
                tcpSocket = {
                  port = 3909
                }
                initialDelaySeconds = 5
                periodSeconds       = 10
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              livenessProbe = {
                tcpSocket = {
                  port = 3909
                }
                initialDelaySeconds = 30
                periodSeconds       = 20
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = true
                runAsNonRoot             = true
                runAsUser                = 1000
                runAsGroup               = 1000
                capabilities = {
                  drop = ["ALL"]
                }
              }
            },
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.admin_service,
    kubernetes_manifest.api_service,
    kubernetes_secret_v1.garage_secrets,
    null_resource.garage_layout,
  ]
}

resource "kubernetes_manifest" "console_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.console_service_name
      namespace = local.s3_namespace_value
      labels = {
        app                         = local.console_service_name
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      selector = {
        app = local.console_service_name
      }
      ports = [
        { name = "http", port = 3909, targetPort = 3909 },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "console_oauth2_proxy_deployment" {
  count = local.garage_console_auth_enabled ? 1 : 0

  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "console-oauth2-proxy"
      namespace = local.s3_namespace_value
      labels = {
        app                         = "console-oauth2-proxy"
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "console-oauth2-proxy"
        }
      }
      template = {
        metadata = {
          labels = {
            app                         = "console-oauth2-proxy"
            "app.kubernetes.io/part-of" = "garage"
          }
        }
        spec = {
          automountServiceAccountToken = false
          priorityClassName            = "infra-observability"
          securityContext = {
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          containers = [
            {
              name            = "oauth2-proxy"
              image           = "quay.io/oauth2-proxy/oauth2-proxy:${local.garage_oauth2_proxy_image_tag_value}"
              imagePullPolicy = "IfNotPresent"
              args = compact(concat(
                [
                  "--http-address=0.0.0.0:4180",
                  "--provider=keycloak-oidc",
                  "--oidc-issuer-url=${local.garage_console_oidc_issuer}",
                  "--client-id=${local.garage_console_oidc_client_id}",
                  "--client-secret-file=/etc/oauth2-proxy/client-secret",
                  "--cookie-secret-file=/etc/oauth2-proxy/cookie-secret",
                  "--cookie-name=${local.garage_console_oauth_cookie_name_value}",
                  "--cookie-secure=true",
                  "--cookie-samesite=lax",
                  "--email-domain=*",
                  "--reverse-proxy=true",
                  "--scope=openid profile email",
                  "--set-authorization-header=true",
                  "--set-xauthrequest=true",
                  "--skip-provider-button=true",
                  "--upstream=static://200",
                ],
                local.garage_console_auth_ca_enabled ? [
                  "--provider-ca-file=/etc/oauth2-proxy-ca/ca.crt",
                ] : [],
                local.garage_console_oauth_backend_logout_url != "" ? [
                  "--backend-logout-url=${local.garage_console_oauth_backend_logout_url}",
                ] : []
              ))
              ports = [
                { name = "http", containerPort = 4180 },
              ]
              resources = {
                requests = {
                  cpu    = local.garage_oauth2_proxy_cpu_request_value
                  memory = local.garage_oauth2_proxy_mem_request_value
                }
                limits = {
                  cpu    = local.garage_oauth2_proxy_cpu_limit_value
                  memory = local.garage_oauth2_proxy_mem_limit_value
                }
              }
              startupProbe = {
                httpGet = {
                  path   = "/ping"
                  port   = 4180
                  scheme = "HTTP"
                }
                periodSeconds    = 5
                timeoutSeconds   = 1
                successThreshold = 1
                failureThreshold = 30
              }
              readinessProbe = {
                httpGet = {
                  path   = "/ping"
                  port   = 4180
                  scheme = "HTTP"
                }
                initialDelaySeconds = 5
                periodSeconds       = 10
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              livenessProbe = {
                httpGet = {
                  path   = "/ping"
                  port   = 4180
                  scheme = "HTTP"
                }
                initialDelaySeconds = 30
                periodSeconds       = 20
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = true
                runAsNonRoot             = true
                runAsUser                = 2000
                runAsGroup               = 2000
                capabilities = {
                  drop = ["ALL"]
                }
              }
              volumeMounts = concat(
                [
                  {
                    name      = "oauth-secret"
                    mountPath = "/etc/oauth2-proxy"
                    readOnly  = true
                  },
                ],
                local.garage_console_auth_ca_enabled ? [
                  {
                    name      = "oauth-ca"
                    mountPath = "/etc/oauth2-proxy-ca"
                    readOnly  = true
                  },
                ] : []
              )
            },
          ]
          volumes = concat(
            [
              {
                name = "oauth-secret"
                secret = {
                  secretName  = local.garage_console_oauth_secret_name_value
                  defaultMode = 420
                }
              },
            ],
            local.garage_console_auth_ca_enabled ? [
              {
                name = "oauth-ca"
                secret = {
                  secretName = local.garage_console_auth_ca_secret_name_value
                }
              },
            ] : []
          )
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret_v1.console_oauth,
    kubernetes_secret_v1.console_oauth_ca,
  ]
}

resource "kubernetes_manifest" "console_oauth2_proxy_service" {
  count = local.garage_console_auth_enabled ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "console-oauth2-proxy"
      namespace = local.s3_namespace_value
      labels = {
        app                         = "console-oauth2-proxy"
        "app.kubernetes.io/part-of" = "garage"
      }
    }
    spec = {
      selector = {
        app = "console-oauth2-proxy"
      }
      ports = [
        { name = "http", port = 4180, targetPort = 4180 },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "console_oauth2_proxy_ingress" {
  count = local.garage_console_auth_enabled ? 1 : 0

  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "s3-console-oauth2-proxy"
      namespace = local.s3_namespace_value
    }
    spec = {
      ingressClassName = "nginx"
      tls = [
        {
          hosts      = [local.garage_console_hostname_value]
          secretName = local.garage_console_tls_secret_name_value
        },
      ]
      rules = [
        {
          host = local.garage_console_hostname_value
          http = {
            paths = [
              {
                path     = "/oauth2"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "console-oauth2-proxy"
                    port = {
                      number = 4180
                    }
                  }
                }
              },
            ]
          }
        },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.console_oauth2_proxy_service,
    kubernetes_manifest.certificate,
    kubernetes_secret_v1.preissued_tls,
  ]
}

resource "kubernetes_manifest" "console_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "s3-console"
      namespace = local.s3_namespace_value
      annotations = merge(
        {},
        local.garage_console_auth_enabled ? {
          "nginx.ingress.kubernetes.io/auth-url"    = "http://console-oauth2-proxy.${local.s3_namespace_value}.svc.cluster.local:4180/oauth2/auth"
          "nginx.ingress.kubernetes.io/auth-signin" = "https://$host/oauth2/start?rd=$escaped_request_uri"
        } : {}
      )
    }
    spec = {
      ingressClassName = "nginx"
      tls = [
        {
          hosts      = [local.garage_console_hostname_value]
          secretName = local.garage_console_tls_secret_name_value
        },
      ]
      rules = [
        {
          host = local.garage_console_hostname_value
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = local.console_service_name
                    port = {
                      number = 3909
                    }
                  }
                }
              },
            ]
          }
        },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.console_service,
    kubernetes_manifest.console_oauth2_proxy_ingress,
    kubernetes_manifest.certificate,
    kubernetes_secret_v1.preissued_tls,
  ]
}

output "s3_namespace" {
  value = local.s3_namespace_value
}

output "garage_name" {
  value = local.garage_name_value
}

output "garage_replicas" {
  value = local.garage_replicas_value
}

output "garage_s3_region" {
  value = local.garage_s3_region_value
}

output "garage_s3_endpoint_url" {
  value = "https://${local.garage_s3_hostname_value}"
}

output "garage_internal_s3_endpoint_url" {
  value = local.garage_internal_s3_endpoint_url
}

output "garage_console_url" {
  value = "https://${local.garage_console_hostname_value}"
}

output "garage_admin_token" {
  value     = random_password.garage_admin_token.result
  sensitive = true
}

output "garage_console_auth_enabled" {
  value = local.garage_console_auth_enabled
}
