# Heuristic host budgets. Infrastructure running as pods keeps its own requests.
locals {
  worker_reservation_defaults = {
    worker_system_reserved_cpu                  = "250m"
    worker_system_reserved_memory_min           = "512Mi"
    worker_system_reserved_memory_percent       = "1"
    worker_kube_reserved_cpu_per_pod_millicores = "2"
    worker_kube_reserved_memory_per_pod_mib     = "5"
    worker_eviction_memory_min                  = "512Mi"
    worker_eviction_memory_percent              = "1"
    worker_eviction_memory_max                  = "2Gi"
  }
  worker_reservation_settings = {
    for key, fallback in local.worker_reservation_defaults : key => try(trimspace(var.constants.talos[key]), "") != "" ? trimspace(var.constants.talos[key]) : fallback
  }
  worker_reservation_numeric = {
    for key, value in local.worker_reservation_settings : key => (
      key == "worker_system_reserved_cpu" ? try(tonumber(trimsuffix(value, "m")) * (endswith(value, "m") ? 1 : 1000), -1) :
      can(regex("_(min|max)$", key)) ? try(tonumber(regex("^[0-9]+", value)) * (endswith(value, "Gi") ? 1024 : 1), -1) :
      try(tonumber(value), -1)
    )
  }
  worker_reservation_invalid = concat([
    for key, value in local.worker_reservation_settings : "talos.${key}"
    if !(local.worker_reservation_numeric[key] > 0 && (
      key == "worker_system_reserved_cpu" ? can(regex("^[1-9][0-9]*m?$", value)) :
      can(regex("_(min|max)$", key)) ? can(regex("^[1-9][0-9]*(Mi|Gi)$", value)) :
      can(regex("^[0-9]+(\\.[0-9]+)?$", value)) &&
      (!endswith(key, "_percent") || local.worker_reservation_numeric[key] <= 100)
    ))
    ], local.worker_reservation_numeric.worker_eviction_memory_min <= local.worker_reservation_numeric.worker_eviction_memory_max ? [] : ["talos.worker_eviction_memory_min exceeds maximum"],
    can(regex("^[1-9][0-9]*$", local.worker_reservation_pods_input)) && local.worker_reservation_pods <= 65535 ? [] : ["talos.max_pods"],
    [for name, vm in local.worker_vms : "resources.${vm.type}" if !(
      var.resources[vm.type].vcpus > 0 && var.resources[vm.type].memory > 0 &&
      floor(var.resources[vm.type].memory) == var.resources[vm.type].memory
    )]
  )
  worker_reservation_pods_input = try(coalesce(trimspace(var.constants.talos.max_pods), "110"), "110")
  worker_reservation_pods       = try(tonumber(local.worker_reservation_pods_input), 110)
  worker_reservation_budgets = {
    for name, vm in local.worker_vms : name => {
      system_cpu_m = local.worker_reservation_numeric.worker_system_reserved_cpu
      system_memory_mib = max(
        local.worker_reservation_numeric.worker_system_reserved_memory_min,
        ceil(local.worker_reservation_numeric.worker_system_reserved_memory_percent * var.resources[vm.type].memory / 100 / 256) * 256
      )
      kube_cpu_m      = ceil((250 + local.worker_reservation_numeric.worker_kube_reserved_cpu_per_pod_millicores * local.worker_reservation_pods) / 50) * 50
      kube_memory_mib = ceil((256 + local.worker_reservation_numeric.worker_kube_reserved_memory_per_pod_mib * local.worker_reservation_pods) / 256) * 256
      eviction_memory_mib = min(local.worker_reservation_numeric.worker_eviction_memory_max, max(
        local.worker_reservation_numeric.worker_eviction_memory_min,
        ceil(local.worker_reservation_numeric.worker_eviction_memory_percent * var.resources[vm.type].memory / 100 / 256) * 256
      ))
    }
  }
  worker_reservation_nodes = {
    for name, budget in local.worker_reservation_budgets : name => merge(budget, {
      profile                = var.vms[name].type
      capacity_cpu_m         = var.resources[var.vms[name].type].vcpus * 1000
      capacity_memory_mib    = var.resources[var.vms[name].type].memory
      allocatable_cpu_m      = var.resources[var.vms[name].type].vcpus * 1000 - budget.system_cpu_m - budget.kube_cpu_m
      allocatable_memory_mib = var.resources[var.vms[name].type].memory - budget.system_memory_mib - budget.kube_memory_mib - budget.eviction_memory_mib
      config = {
        systemReserved = {
          cpu    = budget.system_cpu_m % 1000 == 0 ? format("%d", budget.system_cpu_m / 1000) : format("%dm", budget.system_cpu_m)
          memory = budget.system_memory_mib % 1024 == 0 ? format("%dGi", budget.system_memory_mib / 1024) : format("%dMi", budget.system_memory_mib)
        }
        kubeReserved = {
          cpu    = budget.kube_cpu_m % 1000 == 0 ? format("%d", budget.kube_cpu_m / 1000) : format("%dm", budget.kube_cpu_m)
          memory = budget.kube_memory_mib % 1024 == 0 ? format("%dGi", budget.kube_memory_mib / 1024) : format("%dMi", budget.kube_memory_mib)
        }
        evictionHard = {
          "memory.available" = budget.eviction_memory_mib % 1024 == 0 ? format("%dGi", budget.eviction_memory_mib / 1024) : format("%dMi", budget.eviction_memory_mib)
        }
        enforceNodeAllocatable = ["pods"]
      }
    })
  }
  worker_reservations = {
    max_pods = local.worker_reservation_pods
    invalid  = distinct(local.worker_reservation_invalid)
    nodes    = local.worker_reservation_nodes
    fits = alltrue([for node in values(local.worker_reservation_nodes) :
      node.allocatable_cpu_m > 0 && node.allocatable_memory_mib > 0
    ])
  }
}

output "worker_reservations" {
  description = "Calculated worker host reservations and projected pod capacity; no credentials."
  value       = local.worker_reservations
}
