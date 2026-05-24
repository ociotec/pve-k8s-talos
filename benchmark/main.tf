terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  benchmark_namespace_value     = try(local.benchmark_namespace, "benchmark")
  benchmark_stress_image_value  = try(local.benchmark_stress_image, "ghcr.io/colinianking/stress-ng:9df1b93b7f236617210bbad950bdd01998f381b4")
  benchmark_fio_image_value     = try(local.benchmark_fio_image, "ghcr.io/kvaps/fio:3.38")
  benchmark_priority_class_name = "benchmark-low"

  benchmark_cpu_vcpus_value    = try(local.benchmark_cpu_vcpus, 2)
  benchmark_cpu_memory_value   = try(local.benchmark_cpu_memory, "256Mi")
  benchmark_cpu_replicas_value = try(local.benchmark_cpu_replicas, 0)
  benchmark_cpu_worker_count   = max(1, floor(local.benchmark_cpu_vcpus_value))
  benchmark_cpu_workload_name  = format("benchmark-cpu-%dvcpus", local.benchmark_cpu_vcpus_value)

  benchmark_memory_gb_value             = try(local.benchmark_memory_gb, 4)
  benchmark_memory_cpu_value            = try(local.benchmark_memory_cpu, "250m")
  benchmark_memory_replicas_value       = try(local.benchmark_memory_replicas, 0)
  benchmark_memory_stress_percent_value = try(local.benchmark_memory_stress_percent, 85)
  benchmark_memory_bytes_value          = local.benchmark_memory_gb_value * 1024 * 1024 * 1024
  benchmark_memory_stress_bytes         = floor(local.benchmark_memory_bytes_value * local.benchmark_memory_stress_percent_value / 100)
  benchmark_memory_workload_name        = format("benchmark-memory-%dgb", local.benchmark_memory_gb_value)

  benchmark_disk_rate_mbs_value        = try(local.benchmark_disk_rate_mbs, 10)
  benchmark_disk_rate_value            = format("%dM", local.benchmark_disk_rate_mbs_value)
  benchmark_disk_cpu_value             = try(local.benchmark_disk_cpu, "100m")
  benchmark_disk_memory_value          = try(local.benchmark_disk_memory, "128Mi")
  benchmark_disk_replicas_value        = try(local.benchmark_disk_replicas, 0)
  benchmark_disk_pvc_size_value        = try(local.benchmark_disk_pvc_size, "2Gi")
  benchmark_disk_fio_file_size_value   = try(local.benchmark_disk_fio_file_size, "1Gi")
  benchmark_disk_block_size_value      = try(local.benchmark_disk_block_size, "1M")
  benchmark_disk_runtime_value         = try(local.benchmark_disk_runtime, "3600")
  benchmark_disk_storage_classes_value = local.benchmark_disk_storage_classes
  benchmark_enabled_disk_storage_classes = {
    for name, storage_class in local.benchmark_disk_storage_classes_value :
    name => storage_class
    if try(storage_class.enabled, true)
  }
  benchmark_disk_pvc_labels = merge(concat([{}], [
    for storage_class_name, _ in local.benchmark_enabled_disk_storage_classes : {
      for ordinal in range(local.benchmark_disk_replicas_value) :
      format("%s-%d", storage_class_name, ordinal) => {
        name     = format("data-benchmark-disk-%s-%dmbs-%d", storage_class_name, local.benchmark_disk_rate_mbs_value, ordinal)
        workload = format("benchmark-disk-%s-%dmbs", storage_class_name, local.benchmark_disk_rate_mbs_value)
      }
    }
  ])...)
}

check "benchmark_cpu_integer" {
  assert {
    condition     = local.benchmark_cpu_vcpus_value == floor(local.benchmark_cpu_vcpus_value)
    error_message = "benchmark_cpu_vcpus must be an integer so it can be represented in the workload name."
  }
}

check "benchmark_memory_integer" {
  assert {
    condition     = local.benchmark_memory_gb_value == floor(local.benchmark_memory_gb_value)
    error_message = "benchmark_memory_gb must be an integer so it can be represented in the workload name."
  }
}

check "benchmark_memory_stress_percent_range" {
  assert {
    condition     = local.benchmark_memory_stress_percent_value > 0 && local.benchmark_memory_stress_percent_value <= 100
    error_message = "benchmark_memory_stress_percent must be greater than 0 and less than or equal to 100."
  }
}

check "benchmark_disk_rate_integer" {
  assert {
    condition     = local.benchmark_disk_rate_mbs_value == floor(local.benchmark_disk_rate_mbs_value)
    error_message = "benchmark_disk_rate_mbs must be an integer so it can be represented in the workload name."
  }
}

resource "kubernetes_manifest" "namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.benchmark_namespace_value
      labels = {
        "pod-security.kubernetes.io/enforce" = "baseline"
        "pod-security.kubernetes.io/audit"   = "baseline"
        "pod-security.kubernetes.io/warn"    = "baseline"
      }
    }
  }
}

resource "kubernetes_manifest" "priority_class" {
  manifest = {
    apiVersion = "scheduling.k8s.io/v1"
    kind       = "PriorityClass"
    metadata = {
      name = local.benchmark_priority_class_name
      labels = {
        "app.kubernetes.io/managed-by" = "infrastructure"
      }
    }
    value            = -1000
    preemptionPolicy = "Never"
    description      = "Low-priority benchmark workloads that should run below normal application pods."
  }
}

resource "kubernetes_manifest" "cpu_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.benchmark_cpu_workload_name
      namespace = local.benchmark_namespace_value
      labels = {
        app = local.benchmark_cpu_workload_name
      }
    }
    spec = {
      replicas = local.benchmark_cpu_replicas_value
      selector = {
        matchLabels = {
          app = local.benchmark_cpu_workload_name
        }
      }
      template = {
        metadata = {
          labels = {
            app = local.benchmark_cpu_workload_name
          }
        }
        spec = {
          terminationGracePeriodSeconds = 5
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "stress-ng"
              image           = local.benchmark_stress_image_value
              imagePullPolicy = "IfNotPresent"
              args = [
                "--cpu",
                tostring(local.benchmark_cpu_worker_count),
                "--cpu-method",
                "all",
                "--timeout",
                "365d",
                "--metrics-brief",
              ]
              resources = {
                requests = {
                  cpu    = tostring(local.benchmark_cpu_vcpus_value)
                  memory = local.benchmark_cpu_memory_value
                }
                limits = {
                  cpu    = tostring(local.benchmark_cpu_vcpus_value)
                  memory = local.benchmark_cpu_memory_value
                }
              }
            },
          ]
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
  ]
}

resource "kubernetes_manifest" "memory_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.benchmark_memory_workload_name
      namespace = local.benchmark_namespace_value
      labels = {
        app = local.benchmark_memory_workload_name
      }
    }
    spec = {
      replicas = local.benchmark_memory_replicas_value
      selector = {
        matchLabels = {
          app = local.benchmark_memory_workload_name
        }
      }
      template = {
        metadata = {
          labels = {
            app = local.benchmark_memory_workload_name
          }
        }
        spec = {
          terminationGracePeriodSeconds = 5
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "stress-ng"
              image           = local.benchmark_stress_image_value
              imagePullPolicy = "IfNotPresent"
              args = [
                "--vm",
                "1",
                "--vm-bytes",
                tostring(local.benchmark_memory_stress_bytes),
                "--vm-keep",
                "--timeout",
                "365d",
                "--metrics-brief",
              ]
              resources = {
                requests = {
                  cpu    = local.benchmark_memory_cpu_value
                  memory = format("%dGi", local.benchmark_memory_gb_value)
                }
                limits = {
                  cpu    = local.benchmark_memory_cpu_value
                  memory = format("%dGi", local.benchmark_memory_gb_value)
                }
              }
            },
          ]
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
  ]
}

resource "kubernetes_manifest" "disk_headless_service" {
  for_each = local.benchmark_enabled_disk_storage_classes

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      namespace = local.benchmark_namespace_value
      labels = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
    }
    spec = {
      clusterIP = "None"
      selector = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
      ports = [
        {
          name = "fio"
          port = 8765
        },
      ]
    }
  }

  depends_on = [kubernetes_manifest.namespace]
}

resource "kubernetes_manifest" "disk_statefulset" {
  for_each = local.benchmark_enabled_disk_storage_classes

  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata = {
      name      = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      namespace = local.benchmark_namespace_value
      labels = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
    }
    spec = {
      replicas    = local.benchmark_disk_replicas_value
      serviceName = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      selector = {
        matchLabels = {
          app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
        }
      }
      template = {
        metadata = {
          labels = {
            app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
          }
        }
        spec = {
          terminationGracePeriodSeconds = 10
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "fio"
              image           = local.benchmark_fio_image_value
              imagePullPolicy = "IfNotPresent"
              command         = ["/bin/sh", "-ec"]
              args = [
                <<-EOT
                while true; do
                  fio \
                    --name="${each.key}-${local.benchmark_disk_rate_value}" \
                    --directory=/data \
                    --filename=/data/fio-benchmark.dat \
                    --rw=rw \
                    --rwmixread=50 \
                    --bs="${local.benchmark_disk_block_size_value}" \
                    --rate="${local.benchmark_disk_rate_value}" \
                    --size="${local.benchmark_disk_fio_file_size_value}" \
                    --time_based=1 \
                    --runtime="${local.benchmark_disk_runtime_value}" \
                    --ioengine=psync \
                    --direct=1 \
                    --group_reporting
                  sleep 5
                done
                EOT
              ]
              resources = {
                requests = {
                  cpu    = local.benchmark_disk_cpu_value
                  memory = local.benchmark_disk_memory_value
                }
                limits = {
                  cpu    = local.benchmark_disk_cpu_value
                  memory = local.benchmark_disk_memory_value
                }
              }
              volumeMounts = [
                {
                  name      = "data"
                  mountPath = "/data"
                },
              ]
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
            accessModes      = try(each.value.access_modes, ["ReadWriteOnce"])
            storageClassName = each.value.storage_class_name
            resources = {
              requests = {
                storage = local.benchmark_disk_pvc_size_value
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

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
    kubernetes_manifest.disk_headless_service,
  ]
}

resource "kubernetes_labels" "disk_data_pvc" {
  for_each = local.benchmark_disk_pvc_labels

  api_version = "v1"
  kind        = "PersistentVolumeClaim"
  force       = true

  metadata {
    name      = each.value.name
    namespace = local.benchmark_namespace_value
  }

  labels = {
    app                            = each.value.workload
    "app.kubernetes.io/name"       = each.value.workload
    "app.kubernetes.io/instance"   = each.value.workload
    "app.kubernetes.io/component"  = "disk"
    "app.kubernetes.io/part-of"    = "benchmark"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "benchmark"
    "pve-k8s-talos/storage-role"   = "benchmark"
  }

  depends_on = [
    kubernetes_manifest.disk_statefulset,
  ]
}

output "benchmark_namespace" {
  value = local.benchmark_namespace_value
}

output "benchmark_cpu_workload" {
  value = local.benchmark_cpu_workload_name
}

output "benchmark_memory_workload" {
  value = local.benchmark_memory_workload_name
}

output "benchmark_disk_workloads" {
  value = [
    for name in keys(local.benchmark_enabled_disk_storage_classes) :
    format("benchmark-disk-%s-%dmbs", name, local.benchmark_disk_rate_mbs_value)
  ]
}

output "benchmark_disk_workload_summary" {
  value = join(" ", [
    for name in keys(local.benchmark_enabled_disk_storage_classes) :
    format("benchmark-disk-%s-%dmbs", name, local.benchmark_disk_rate_mbs_value)
  ])
}
