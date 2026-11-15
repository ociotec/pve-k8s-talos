variable "constants" {
  type        = any
  default     = {}
  description = "Shared cluster constants; optional worker headroom overrides live under k8s."
}

locals {
  # Authoritative sizing defaults. Sample configuration contains alternatives only.
  worker_headroom_enabled           = try(tobool(var.constants.k8s.headroom_enabled), true)
  worker_headroom_cpu_percent       = try(tonumber(try(var.constants.k8s.headroom_cpu_percent, 0)), -1)
  worker_headroom_memory_percent    = try(tonumber(try(var.constants.k8s.headroom_memory_percent, 0)), -1)
  worker_headroom_cpu_min_m         = try(tonumber(try(var.constants.k8s.headroom_cpu_min_millicores, 1)), -1)
  worker_headroom_memory_min_mib    = try(tonumber(try(var.constants.k8s.headroom_memory_min_mib, 8)), -1)
  worker_headroom_cpu_limit_floor_m = 10
  worker_headroom_image             = "registry.k8s.io/pause:3.10.1@sha256:278fb9dbcca9518083ad1e11276933a2e96f23de604a3a08cc3c80002767d24c"
  worker_headroom_labels = {
    "app.kubernetes.io/name"       = "worker-headroom"
    "app.kubernetes.io/component"  = "reservation"
    "app.kubernetes.io/part-of"    = "worker-headroom"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "k8s-net"
  }
  worker_headroom_probe_exception = {
    "policy.pve-k8s-talos.io/allow-missing-probes" = "true"
    "policy.pve-k8s-talos.io/exception-reason"     = "The pinned pause process only waits for signals and exposes no service health endpoint; pod readiness verifies the reservation."
  }
  worker_headroom_nodes = local.worker_headroom_enabled ? {
    for node in data.kubernetes_resources.worker_headroom_nodes[0].objects : node.metadata.name => node
    if !contains(keys(try(node.metadata.labels, {})), "node-role.kubernetes.io/control-plane") &&
    !contains(keys(try(node.metadata.labels, {})), "node-role.kubernetes.io/master")
  } : {}
  worker_headroom_capacity = {
    for name, node in local.worker_headroom_nodes : name => {
      cpu_m = tonumber(trimsuffix(node.status.allocatable.cpu, "m")) * (endswith(node.status.allocatable.cpu, "m") ? 1 : 1000)
      memory_mib = tonumber(regex("^([0-9.]+)", node.status.allocatable.memory)[0]) * lookup({
        "" = 1, Ki = 1024, Mi = 1048576, Gi = 1073741824, Ti = 1099511627776,
        k  = 1000, M = 1000000, G = 1000000000, T = 1000000000000
      }, regex("([A-Za-z]*)$", node.status.allocatable.memory)[0], 0) / 1048576
      pods = tonumber(node.status.allocatable.pods)
    }
  }
  # Round upward to whole millicores and MiB, then enforce independent floors.
  # Keep the CPU limit above its request: Burstable avoids exclusive CPUs under
  # CPU Manager static, so other workloads can still use physically idle CPU.
  worker_headroom_budgets = {
    for name, capacity in local.worker_headroom_capacity : name => {
      cpu_request_m          = max(ceil(local.worker_headroom_cpu_min_m), ceil(capacity.cpu_m * local.worker_headroom_cpu_percent / 100))
      cpu_limit_m            = max(local.worker_headroom_cpu_limit_floor_m, max(ceil(local.worker_headroom_cpu_min_m), ceil(capacity.cpu_m * local.worker_headroom_cpu_percent / 100)) + 1)
      memory_mib             = max(ceil(local.worker_headroom_memory_min_mib), ceil(capacity.memory_mib * local.worker_headroom_memory_percent / 100))
      allocatable_cpu_m      = capacity.cpu_m
      allocatable_memory_mib = capacity.memory_mib
      allocatable_pods       = capacity.pods
      daemonset              = "worker-headroom-${substr(sha256(name), 0, 12)}"
    }
  }
}

data "kubernetes_resources" "worker_headroom_nodes" {
  count       = local.worker_headroom_enabled ? 1 : 0
  api_version = "v1"
  kind        = "Node"
}

resource "terraform_data" "worker_headroom_settings" {
  input = local.worker_headroom_enabled
  lifecycle {
    precondition {
      condition = can(tobool(try(var.constants.k8s.headroom_enabled, true))) && alltrue([
        for value in [local.worker_headroom_cpu_percent, local.worker_headroom_memory_percent] : value >= 0 && value < 100
      ]) && local.worker_headroom_cpu_min_m > 0 && local.worker_headroom_memory_min_mib > 0
      error_message = "Headroom percentages must be in [0,100); CPU and memory minimums must be positive."
    }
    precondition {
      condition = alltrue([
        for name, budget in local.worker_headroom_budgets :
        budget.cpu_request_m < budget.allocatable_cpu_m && budget.memory_mib < budget.allocatable_memory_mib && budget.allocatable_pods > 0
      ])
      error_message = "Worker headroom must leave usable CPU and memory capacity on every worker."
    }
  }
}

resource "kubernetes_daemon_set_v1" "worker_headroom" {
  for_each         = local.worker_headroom_budgets
  wait_for_rollout = false # The deployment gate reports Pending pods and displacement.
  metadata {
    name        = each.value.daemonset
    namespace   = "kube-system"
    labels      = merge(local.worker_headroom_labels, { "app.kubernetes.io/instance" = each.value.daemonset })
    annotations = local.worker_headroom_probe_exception
  }
  spec {
    min_ready_seconds      = 5
    revision_history_limit = 2
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "worker-headroom"
        "app.kubernetes.io/instance" = each.value.daemonset
      }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
        max_surge       = "0"
      }
    }
    template {
      metadata {
        labels      = merge(local.worker_headroom_labels, { "app.kubernetes.io/instance" = each.value.daemonset })
        annotations = local.worker_headroom_probe_exception
      }
      spec {
        priority_class_name              = "infra-headroom"
        automount_service_account_token  = false
        enable_service_links             = false
        termination_grace_period_seconds = 5
        security_context {
          run_as_non_root = true
          run_as_user     = 65535
          run_as_group    = 65535
          seccomp_profile { type = "RuntimeDefault" }
        }
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_fields {
                  key      = "metadata.name"
                  operator = "In"
                  values   = [each.key]
                }
                match_expressions {
                  key      = "node-role.kubernetes.io/control-plane"
                  operator = "DoesNotExist"
                }
                match_expressions {
                  key      = "node-role.kubernetes.io/master"
                  operator = "DoesNotExist"
                }
              }
            }
          }
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector {
                match_labels = { "app.kubernetes.io/part-of" = "worker-headroom" }
              }
            }
          }
        }
        container {
          name              = "pause"
          image             = local.worker_headroom_image
          image_pull_policy = "IfNotPresent"
          resources {
            requests = {
              cpu    = each.value.cpu_request_m % 1000 == 0 ? tostring(each.value.cpu_request_m / 1000) : "${each.value.cpu_request_m}m"
              memory = each.value.memory_mib % 1024 == 0 ? "${each.value.memory_mib / 1024}Gi" : "${each.value.memory_mib}Mi"
            }
            limits = {
              cpu    = each.value.cpu_limit_m % 1000 == 0 ? tostring(each.value.cpu_limit_m / 1000) : "${each.value.cpu_limit_m}m"
              memory = each.value.memory_mib % 1024 == 0 ? "${each.value.memory_mib / 1024}Gi" : "${each.value.memory_mib}Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }
  }
  depends_on = [terraform_data.worker_headroom_settings, kubernetes_priority_class_v1.infrastructure]
}

output "worker_headroom" {
  description = "Calculated per-worker scheduling reservations; percentages are independent of actual pause consumption."
  value = {
    enabled        = local.worker_headroom_enabled
    cpu_percent    = local.worker_headroom_cpu_percent
    memory_percent = local.worker_headroom_memory_percent
    nodes          = local.worker_headroom_budgets
  }
}
