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
  }
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

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  redpanda_namespace_value                   = try(local.redpanda_namespace, "kafka")
  redpanda_resource_name_value               = try(local.redpanda_resource_name, "redpanda")
  redpanda_cluster_id_value                  = try(local.redpanda_cluster_id, "GCS")
  redpanda_broker_k8s_annotation_value       = try(local.redpanda_broker_k8s_annotation, "kafka-node")
  redpanda_broker_data_host_path_value       = try(local.redpanda_broker_data_host_path, "/var/lib/kafka")
  redpanda_console_hostname_value            = try(local.redpanda_console_hostname, "redpanda-console.${local.domain}")
  redpanda_console_tls_secret_name_value     = try(local.redpanda_console_tls_secret_name, "redpanda-console-tls")
  redpanda_image_value                       = try(local.redpanda_image, "docker.redpanda.com/redpandadata/redpanda:v26.1.6")
  redpanda_console_image_value               = try(local.redpanda_console_image, "docker.redpanda.com/redpandadata/console:v3.7.2")
  redpanda_storage_class_name_value          = try(local.redpanda_storage_class_name, "${local.redpanda_resource_name_value}-local")
  redpanda_broker_cpu_request_value          = try(local.redpanda_broker_cpu_request, "2")
  redpanda_broker_cpu_limit_value            = try(local.redpanda_broker_cpu_limit, "2500m")
  redpanda_broker_mem_request_value          = try(local.redpanda_broker_mem_request, "5Gi")
  redpanda_broker_mem_limit_value            = try(local.redpanda_broker_mem_limit, "5Gi")
  redpanda_enable_smp_memory_flags_value     = try(local.redpanda_enable_smp_memory_flags, true)
  redpanda_smp_value                         = try(local.redpanda_smp, 2)
  redpanda_memory_value                      = try(local.redpanda_memory, "4Gi")
  redpanda_config_renderer_cpu_request_value = try(local.redpanda_config_renderer_cpu_request, "50m")
  redpanda_config_renderer_cpu_limit_value   = try(local.redpanda_config_renderer_cpu_limit, "200m")
  redpanda_config_renderer_mem_request_value = try(local.redpanda_config_renderer_mem_request, "64Mi")
  redpanda_config_renderer_mem_limit_value   = try(local.redpanda_config_renderer_mem_limit, "64Mi")
  redpanda_console_cpu_request_value         = try(local.redpanda_console_cpu_request, "100m")
  redpanda_console_cpu_limit_value           = try(local.redpanda_console_cpu_limit, "500m")
  redpanda_console_mem_request_value         = try(local.redpanda_console_mem_request, "256Mi")
  redpanda_console_mem_limit_value           = try(local.redpanda_console_mem_limit, "512Mi")
  tls_source_value                           = try(local.tls_source, "ca_issuer")

  broker_label_values = [
    for _, vm in var.vms : try(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value], null)
    if try(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value], null) != null
  ]
  broker_label_values_numeric = [
    for value in local.broker_label_values : tonumber(value)
    if can(tonumber(value))
  ]
  broker_vms_by_id = {
    for name, vm in var.vms :
    tostring(tonumber(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value])) => merge(vm, {
      name      = name
      broker_id = tonumber(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value])
    })
    if try(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value], null) != null && can(tonumber(vm.k8s_labels[local.redpanda_broker_k8s_annotation_value]))
  }
  broker_ids          = sort([for broker in values(local.broker_vms_by_id) : broker.broker_id])
  broker_count        = length(local.broker_ids)
  expected_broker_ids = [for id in range(local.broker_count) : tostring(id)]

  broker_data_disks_by_id = {
    for broker_id, broker in local.broker_vms_by_id :
    broker_id => [
      for disk in var.resources[broker.type].disks : disk
      if try(disk.mount, "") == local.redpanda_broker_data_host_path_value
    ]
  }
  broker_data_disk_capacity_by_id = {
    for broker_id, disks in local.broker_data_disks_by_id :
    broker_id => format("%dGi", disks[0].size)
    if length(disks) == 1
  }
  broker_data_disk_sizes = [
    for _, disks in local.broker_data_disks_by_id : disks[0].size
    if length(disks) == 1
  ]
  broker_dns_names = [
    for broker_id in local.broker_ids :
    format("%s-%d.%s.%s.svc.cluster.local", local.redpanda_resource_name_value, broker_id, local.redpanda_resource_name_value, local.redpanda_namespace_value)
  ]
  broker_seed_servers_yaml = join("\n", [
    for broker_dns_name in local.broker_dns_names : format("    - host:\n        address: %s\n        port: 33145", broker_dns_name)
  ])
  broker_bootstrap_config = {
    cluster_id                   = local.redpanda_cluster_id_value
    core_balancing_continuous    = "false"
    partition_autobalancing_mode = "node_add"
  }
  broker_bootstrap_yaml = yamlencode(local.broker_bootstrap_config)
  broker_start_flags = local.redpanda_enable_smp_memory_flags_value ? [
    format("--smp=%s", tostring(local.redpanda_smp_value)),
    format("--memory=%s", local.redpanda_memory_value),
  ] : []

  kafka_broker_urls = [
    for broker_dns_name in local.broker_dns_names : "${broker_dns_name}:9092"
  ]
  redpanda_admin_urls = [
    for broker_dns_name in local.broker_dns_names : "http://${broker_dns_name}:9644"
  ]
  schema_registry_urls = [
    for broker_dns_name in local.broker_dns_names : "http://${broker_dns_name}:8081"
  ]
  console_config = yamlencode({
    kafka = {
      brokers = local.kafka_broker_urls
    }
    redpanda = {
      adminApi = {
        enabled = true
        urls    = local.redpanda_admin_urls
      }
    }
    schemaRegistry = {
      enabled = true
      urls    = local.schema_registry_urls
    }
  })
  console_certificate_manifests = local.tls_source_value == "ca_issuer" ? {
    console = {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "${local.redpanda_resource_name_value}-console-ingress-cert"
        namespace = local.redpanda_namespace_value
      }
      spec = {
        secretName = local.redpanda_console_tls_secret_name_value
        issuerRef = {
          name = "root-ca"
          kind = "ClusterIssuer"
        }
        dnsNames = [
          local.redpanda_console_hostname_value,
        ]
      }
    }
  } : {}
  kafka_tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = local.redpanda_namespace_value
      secret_name = local.redpanda_console_tls_secret_name_value
    },
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.kafka_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
}

check "broker_labels_numeric" {
  assert {
    condition     = length(local.broker_label_values) == length(local.broker_label_values_numeric)
    error_message = format("All %s labels used for Redpanda brokers must be numeric.", local.redpanda_broker_k8s_annotation_value)
  }
}

check "broker_labels_minimum" {
  assert {
    condition     = local.broker_count >= 3
    error_message = format("At least 3 Redpanda brokers are required; found %d VMs with label %s.", local.broker_count, local.redpanda_broker_k8s_annotation_value)
  }
}

check "broker_labels_unique" {
  assert {
    condition     = length(local.broker_ids) == length(distinct(local.broker_ids))
    error_message = format("Redpanda broker labels %s must be unique.", local.redpanda_broker_k8s_annotation_value)
  }
}

check "broker_labels_contiguous" {
  assert {
    condition     = join(",", local.broker_ids) == join(",", local.expected_broker_ids)
    error_message = format("Redpanda broker labels %s must be contiguous integers from 0 to N-1; got %s.", local.redpanda_broker_k8s_annotation_value, join(", ", [for id in local.broker_ids : tostring(id)]))
  }
}

check "broker_data_disks" {
  assert {
    condition = alltrue([
      for _, disks in local.broker_data_disks_by_id : length(disks) == 1
    ])
    error_message = format("Each Redpanda broker VM type must define exactly one resources disk mounted at %s.", local.redpanda_broker_data_host_path_value)
  }
}

check "broker_data_disk_sizes" {
  assert {
    condition     = length(local.broker_data_disk_sizes) == local.broker_count && length(distinct(local.broker_data_disk_sizes)) == 1
    error_message = "All Redpanda broker data disks must have the same size in v1."
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
    error_message = "default_certificate_name must reference a readable certificate/key pair in available_certificates for Redpanda Console."
  }
}

resource "kubernetes_manifest" "namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.redpanda_namespace_value
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  }
}

resource "kubernetes_manifest" "storage_class" {
  manifest = {
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = local.redpanda_storage_class_name_value
    }
    provisioner          = "kubernetes.io/no-provisioner"
    volumeBindingMode    = "WaitForFirstConsumer"
    reclaimPolicy        = "Retain"
    allowVolumeExpansion = false
  }
}

resource "kubernetes_manifest" "broker_pv" {
  for_each = local.broker_vms_by_id

  manifest = {
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata = {
      name = format("%s-data-%s", local.redpanda_resource_name_value, each.key)
      labels = {
        app                                          = local.redpanda_resource_name_value
        (local.redpanda_broker_k8s_annotation_value) = each.key
      }
    }
    spec = {
      capacity = {
        storage = local.broker_data_disk_capacity_by_id[each.key]
      }
      accessModes                   = ["ReadWriteOnce"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = local.redpanda_storage_class_name_value
      volumeMode                    = "Filesystem"
      local = {
        path = local.redpanda_broker_data_host_path_value
      }
      claimRef = {
        namespace = local.redpanda_namespace_value
        name      = format("datadir-%s-%s", local.redpanda_resource_name_value, each.key)
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

resource "kubernetes_manifest" "headless_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.redpanda_resource_name_value
      namespace = local.redpanda_namespace_value
      labels = {
        app = local.redpanda_resource_name_value
      }
    }
    spec = {
      clusterIP                = "None"
      publishNotReadyAddresses = true
      selector = {
        app = local.redpanda_resource_name_value
      }
      ports = [
        { name = "kafka", port = 9092, targetPort = 9092 },
        { name = "rpc", port = 33145, targetPort = 33145 },
        { name = "admin", port = 9644, targetPort = 9644 },
        { name = "schema-registry", port = 8081, targetPort = 8081 },
        { name = "proxy", port = 8082, targetPort = 8082 },
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
      name      = local.redpanda_resource_name_value
      namespace = local.redpanda_namespace_value
      labels = {
        app = local.redpanda_resource_name_value
      }
    }
    spec = {
      serviceName         = local.redpanda_resource_name_value
      replicas            = local.broker_count
      podManagementPolicy = "Parallel"
      selector = {
        matchLabels = {
          app = local.redpanda_resource_name_value
        }
      }
      template = {
        metadata = {
          labels = {
            app = local.redpanda_resource_name_value
          }
        }
        spec = {
          terminationGracePeriodSeconds = 120
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      app = local.redpanda_resource_name_value
                    }
                  }
                  topologyKey = "kubernetes.io/hostname"
                },
              ]
            }
          }
          initContainers = [
            {
              name            = "config-renderer"
              image           = local.redpanda_image_value
              imagePullPolicy = "IfNotPresent"
              command         = ["/bin/sh", "-ec"]
              args = [
                <<-EOT
                mkdir -p /var/lib/redpanda/data
                chown -R 101:101 /var/lib/redpanda/data
                chmod 750 /var/lib/redpanda/data

                POD_FQDN="$${POD_NAME}.${local.redpanda_resource_name_value}.${local.redpanda_namespace_value}.svc.cluster.local"
                cat > /etc/redpanda/redpanda.yaml <<EOF
                redpanda:
                  data_directory: /var/lib/redpanda/data
                  empty_seed_starts_cluster: false
                  seed_servers:
                ${local.broker_seed_servers_yaml}
                  rpc_server:
                    address: 0.0.0.0
                    port: 33145
                  advertised_rpc_api:
                    address: $${POD_FQDN}
                    port: 33145
                  kafka_api:
                    - name: internal
                      address: 0.0.0.0
                      port: 9092
                  advertised_kafka_api:
                    - name: internal
                      address: $${POD_FQDN}
                      port: 9092
                  admin:
                    - address: 0.0.0.0
                      port: 9644
                schema_registry:
                  schema_registry_api:
                    - name: internal
                      address: 0.0.0.0
                      port: 8081
                pandaproxy:
                  pandaproxy_api:
                    - name: internal
                      address: 0.0.0.0
                      port: 8082
                EOF
                cat > /etc/redpanda/.bootstrap.yaml <<EOF
                ${local.broker_bootstrap_yaml}
                EOF
                EOT
              ]
              env = [
                {
                  name = "POD_NAME"
                  valueFrom = {
                    fieldRef = {
                      fieldPath = "metadata.name"
                    }
                  }
                },
              ]
              resources = {
                requests = {
                  cpu    = local.redpanda_config_renderer_cpu_request_value
                  memory = local.redpanda_config_renderer_mem_request_value
                }
                limits = {
                  cpu    = local.redpanda_config_renderer_cpu_limit_value
                  memory = local.redpanda_config_renderer_mem_limit_value
                }
              }
              securityContext = {
                runAsUser  = 0
                runAsGroup = 0
              }
              volumeMounts = [
                {
                  name      = "config"
                  mountPath = "/etc/redpanda"
                },
                {
                  name      = "datadir"
                  mountPath = "/var/lib/redpanda/data"
                },
              ]
            },
          ]
          containers = [
            {
              name            = "redpanda"
              image           = local.redpanda_image_value
              imagePullPolicy = "IfNotPresent"
              command         = concat(["rpk", "redpanda", "start", "--check=false"], local.broker_start_flags)
              ports = [
                { name = "kafka", containerPort = 9092 },
                { name = "rpc", containerPort = 33145 },
                { name = "admin", containerPort = 9644 },
                { name = "schema", containerPort = 8081 },
                { name = "proxy", containerPort = 8082 },
              ]
              resources = {
                requests = {
                  cpu    = local.redpanda_broker_cpu_request_value
                  memory = local.redpanda_broker_mem_request_value
                }
                limits = {
                  cpu    = local.redpanda_broker_cpu_limit_value
                  memory = local.redpanda_broker_mem_limit_value
                }
              }
              readinessProbe = {
                httpGet = {
                  path   = "/v1/status/ready"
                  port   = 9644
                  scheme = "HTTP"
                }
                initialDelaySeconds = 10
                periodSeconds       = 10
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 12
              }
              livenessProbe = {
                httpGet = {
                  path   = "/v1/status/ready"
                  port   = 9644
                  scheme = "HTTP"
                }
                initialDelaySeconds = 30
                periodSeconds       = 20
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              startupProbe = {
                httpGet = {
                  path   = "/v1/status/ready"
                  port   = 9644
                  scheme = "HTTP"
                }
                periodSeconds    = 10
                timeoutSeconds   = 1
                successThreshold = 1
                failureThreshold = 90
              }
              volumeMounts = [
                {
                  name      = "config"
                  mountPath = "/etc/redpanda"
                },
                {
                  name      = "datadir"
                  mountPath = "/var/lib/redpanda/data"
                },
              ]
            },
          ]
          volumes = [
            {
              name     = "config"
              emptyDir = {}
            },
          ]
        }
      }
      volumeClaimTemplates = [
        {
          metadata = {
            name = "datadir"
          }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = local.redpanda_storage_class_name_value
            resources = {
              requests = {
                storage = format("%dGi", local.broker_data_disk_sizes[0])
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
    kubernetes_manifest.storage_class,
    kubernetes_manifest.broker_pv,
    kubernetes_manifest.headless_service,
  ]
}

resource "null_resource" "community_feature_config" {
  count = 1

  triggers = {
    namespace                    = local.redpanda_namespace_value
    resource_name                = local.redpanda_resource_name_value
    core_balancing_continuous    = "false"
    partition_autobalancing_mode = "node_add"
    kubeconfig_path              = abspath("${path.module}/${var.kubeconfig_path}")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${self.triggers.kubeconfig_path}"
      kubectl -n "${self.triggers.namespace}" rollout status statefulset/"${self.triggers.resource_name}" --timeout=900s
      kubectl -n "${self.triggers.namespace}" exec "${self.triggers.resource_name}-0" -- rpk cluster config set partition_autobalancing_mode "${self.triggers.partition_autobalancing_mode}"
      kubectl -n "${self.triggers.namespace}" exec "${self.triggers.resource_name}-0" -- rpk cluster config set core_balancing_continuous "${self.triggers.core_balancing_continuous}"
    EOT
  }

  depends_on = [
    kubernetes_manifest.statefulset,
  ]
}

resource "kubernetes_manifest" "console_config" {
  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "${local.redpanda_resource_name_value}-console-config"
      namespace = local.redpanda_namespace_value
      labels = {
        app = "${local.redpanda_resource_name_value}-console"
      }
    }
    data = {
      "config.yaml" = local.console_config
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "console_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "${local.redpanda_resource_name_value}-console"
      namespace = local.redpanda_namespace_value
      labels = {
        app = "${local.redpanda_resource_name_value}-console"
      }
    }
    spec = {
      selector = {
        app = "${local.redpanda_resource_name_value}-console"
      }
      ports = [
        {
          name       = "http"
          port       = 8080
          targetPort = 8080
        },
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.namespace,
  ]
}

resource "kubernetes_manifest" "console_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "${local.redpanda_resource_name_value}-console"
      namespace = local.redpanda_namespace_value
      labels = {
        app = "${local.redpanda_resource_name_value}-console"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "${local.redpanda_resource_name_value}-console"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "${local.redpanda_resource_name_value}-console"
          }
        }
        spec = {
          containers = [
            {
              name            = "console"
              image           = local.redpanda_console_image_value
              imagePullPolicy = "IfNotPresent"
              env = [
                {
                  name  = "CONFIG_FILEPATH"
                  value = "/etc/redpanda-console/config.yaml"
                },
              ]
              ports = [
                {
                  name          = "http"
                  containerPort = 8080
                },
              ]
              resources = {
                requests = {
                  cpu    = local.redpanda_console_cpu_request_value
                  memory = local.redpanda_console_mem_request_value
                }
                limits = {
                  cpu    = local.redpanda_console_cpu_limit_value
                  memory = local.redpanda_console_mem_limit_value
                }
              }
              readinessProbe = {
                httpGet = {
                  path   = "/health"
                  port   = 8080
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
                  path   = "/health"
                  port   = 8080
                  scheme = "HTTP"
                }
                initialDelaySeconds = 30
                periodSeconds       = 20
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              volumeMounts = [
                {
                  name      = "config"
                  mountPath = "/etc/redpanda-console"
                  readOnly  = true
                },
              ]
            },
          ]
          volumes = [
            {
              name = "config"
              configMap = {
                name = "${local.redpanda_resource_name_value}-console-config"
              }
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "object.spec.template.metadata.annotations",
  ]

  depends_on = [
    kubernetes_manifest.console_config,
    kubernetes_manifest.headless_service,
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

resource "kubernetes_manifest" "console_certificate" {
  for_each = local.console_certificate_manifests
  manifest = each.value

  depends_on = [
    kubernetes_manifest.namespace,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "console_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "${local.redpanda_resource_name_value}-console"
      namespace = local.redpanda_namespace_value
      annotations = {
        "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
      }
    }
    spec = {
      ingressClassName = "nginx"
      tls = [
        {
          hosts      = [local.redpanda_console_hostname_value]
          secretName = local.redpanda_console_tls_secret_name_value
        },
      ]
      rules = [
        {
          host = local.redpanda_console_hostname_value
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "${local.redpanda_resource_name_value}-console"
                    port = {
                      number = 8080
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
    kubernetes_manifest.console_deployment,
    kubernetes_manifest.console_certificate,
    kubernetes_secret_v1.preissued_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "redpanda_namespace" {
  value = local.redpanda_namespace_value
}

output "redpanda_resource_name" {
  value = local.redpanda_resource_name_value
}

output "redpanda_broker_count" {
  value = local.broker_count
}

output "redpanda_console_url" {
  value = "https://${local.redpanda_console_hostname_value}"
}
