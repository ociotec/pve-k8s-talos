# Provisioning estimates, evaluated from the final declared worker fleet before
# nodes exist. These are not measured workload or API-throughput guarantees.
variable "allow_control_plane_overcommit" {
  type        = bool
  default     = false
  description = "Explicitly bypass only the control-plane capacity gate for this run."
}

locals {
  cp_worker_count      = length(local.worker_vms)
  cp_worker_vcpu       = sum(concat([0], [for vm in values(local.worker_vms) : var.resources[vm.type].vcpus]))
  cp_worker_memory_gib = sum(concat([0], [for vm in values(local.worker_vms) : var.resources[vm.type].memory])) / 1024
  cp_max_pods_input    = try(coalesce(var.constants.talos.max_pods, ""), "")
  cp_max_pods          = coalesce(try(tonumber(local.cp_max_pods_input), null), 110)
  cp_headroom_input    = try(coalesce(var.constants.talos.control_plane_recommended_headroom_percent, ""), "")
  cp_headroom_percent  = coalesce(try(tonumber(local.cp_headroom_input), null), 20)
  cp_invalid_settings = concat(
    local.cp_max_pods_input == "" || (
      can(regex("^[1-9][0-9]*$", local.cp_max_pods_input)) && local.cp_max_pods <= 65535
    ) ? [] : ["talos.max_pods"],
    local.cp_headroom_input == "" || can(regex("^([0-9]|[1-9][0-9])$", local.cp_headroom_input)) ? [] : ["talos.control_plane_recommended_headroom_percent"]
  )
  # Ten 110-pod workers or the existing 328-vCPU/420-GiB capacity reference
  # form one baseline. Use the limiting worker resource for workload capacity,
  # but retain node/pod-density pressure independently of worker VM size.
  cp_capacity_factor = max(
    1,
    local.cp_worker_count / 10,
    local.cp_worker_count * local.cp_max_pods / 1100,
    min(local.cp_worker_vcpu / 328, local.cp_worker_memory_gib / 420)
  )
  cp_component_baseline = {
    api_server         = { cpu_m = 1000, memory_mib = 3072 }
    controller_manager = { cpu_m = 500, memory_mib = 1024 }
    scheduler          = { cpu_m = 250, memory_mib = 512 }
  }
  cp_automatic_numeric = {
    for name, resources in local.cp_component_baseline : name => {
      cpu_m      = ceil(resources.cpu_m * local.cp_capacity_factor / 250) * 250
      memory_mib = ceil(resources.memory_mib * local.cp_capacity_factor / 128) * 128
    }
  }
  # Native Talos services do not have Kubernetes resource limits. Account for
  # them as budgets rather than inventing unsupported etcd resource settings.
  cp_budget_defaults = {
    etcd        = { cpu_m = ceil(500 * local.cp_capacity_factor / 250) * 250, memory_mib = ceil(512 * local.cp_capacity_factor / 128) * 128 }
    system      = { cpu_m = 500, memory_mib = 1024 }
    node_agents = { cpu_m = 250, memory_mib = 512 }
  }
  cp_resource_defaults = merge(local.cp_automatic_numeric, {
    for name, resources in local.cp_budget_defaults : "${name}_reserve" => resources
  })
  cp_resource_strings = {
    for name, resources in local.cp_resource_defaults : name => {
      cpu = try(trimspace(var.constants.talos["${name}_cpu"]), "") != "" ? var.constants.talos["${name}_cpu"] : (
        resources.cpu_m % 1000 == 0 ? format("%d", resources.cpu_m / 1000) : format("%dm", resources.cpu_m)
      )
      memory = try(trimspace(var.constants.talos["${name}_memory"]), "") != "" ? var.constants.talos["${name}_memory"] : (
        resources.memory_mib % 1024 == 0 ? format("%dGi", resources.memory_mib / 1024) : format("%dMi", resources.memory_mib)
      )
    }
  }
  cp_invalid_resources = [
    for name, resources in local.cp_resource_strings : name
    if !(
      can(regex("^[1-9][0-9]*m?$", resources.cpu)) &&
      can(regex("^[1-9][0-9]*(Mi|Gi)$", resources.memory)) &&
      !(endswith(resources.cpu, "m") && try(tonumber(trimsuffix(resources.cpu, "m")) % 1000 == 0, false)) &&
      !(endswith(resources.memory, "Mi") && try(tonumber(trimsuffix(resources.memory, "Mi")) % 1024 == 0, false)) &&
      ((try(trimspace(var.constants.talos["${name}_cpu"]), "") == "") ==
      (try(trimspace(var.constants.talos["${name}_memory"]), "") == ""))
    )
  ]
  cp_effective_numeric = {
    for name, resources in local.cp_resource_strings : name => {
      cpu_m      = try(tonumber(trimsuffix(resources.cpu, "m")) * (endswith(resources.cpu, "m") ? 1 : 1000), 0)
      memory_mib = try(tonumber(regex("^[0-9]+", resources.memory)) * (endswith(resources.memory, "Gi") ? 1024 : 1), 0)
    }
  }
  cp_total_cpu_m      = sum([for resources in values(local.cp_effective_numeric) : resources.cpu_m])
  cp_total_memory_mib = sum([for resources in values(local.cp_effective_numeric) : resources.memory_mib])
  # The hard minimum only includes components and service budgets. Round VM
  # thresholds up to whole vCPUs and GiB; do not add headroom to the hard gate.
  # Never divide leader requirements by CP count: each member must carry them.
  cp_required_cpu_m      = ceil(local.cp_total_cpu_m / 1000) * 1000
  cp_required_memory_mib = ceil(local.cp_total_memory_mib / 1024) * 1024
  # Headroom defines only the upper recommendation. Clamp invalid inputs here
  # to keep diagnostics evaluable; cp_invalid_settings still rejects them.
  cp_recommended_fraction   = 1 - min(99, max(0, local.cp_headroom_percent)) / 100
  cp_recommended_cpu_m      = ceil(local.cp_total_cpu_m / 1000 / local.cp_recommended_fraction) * 1000
  cp_recommended_memory_mib = ceil(local.cp_total_memory_mib / 1024 / local.cp_recommended_fraction) * 1024
  cp_node_capacity = {
    for name, vm in local.controlplane_vms : name => {
      cpu_m              = var.resources[vm.type].vcpus * 1000
      memory_mib         = var.resources[vm.type].memory
      cpu_deficit_m      = max(0, local.cp_required_cpu_m - var.resources[vm.type].vcpus * 1000)
      memory_deficit_mib = max(0, local.cp_required_memory_mib - var.resources[vm.type].memory)
      fits               = var.resources[vm.type].vcpus * 1000 >= local.cp_required_cpu_m && var.resources[vm.type].memory >= local.cp_required_memory_mib
      cpu_surplus_m      = max(0, var.resources[vm.type].vcpus * 1000 - local.cp_recommended_cpu_m)
      memory_surplus_mib = max(0, var.resources[vm.type].memory - local.cp_recommended_memory_mib)
      oversized          = var.resources[vm.type].vcpus * 1000 > local.cp_recommended_cpu_m || var.resources[vm.type].memory > local.cp_recommended_memory_mib
    }
  }
  cp_capacity_fits   = length(local.controlplane_vms) > 0 && alltrue([for node in values(local.cp_node_capacity) : node.fits])
  cp_oversized_nodes = [for name, node in local.cp_node_capacity : name if node.oversized]
  control_plane_sizing = {
    workers = {
      count      = local.cp_worker_count, vcpu = local.cp_worker_vcpu,
      memory_gib = local.cp_worker_memory_gib, max_pods_per_node = local.cp_max_pods
    }
    capacity_factor              = local.cp_capacity_factor
    automatic                    = local.cp_automatic_numeric
    components                   = { for name in keys(local.cp_component_baseline) : name => local.cp_resource_strings[name] }
    budgets                      = { for name in keys(local.cp_budget_defaults) : name => local.cp_resource_strings["${name}_reserve"] }
    recommended_headroom_percent = local.cp_headroom_percent
    totals = {
      components = {
        cpu_m      = sum([for name in keys(local.cp_component_baseline) : local.cp_effective_numeric[name].cpu_m])
        memory_mib = sum([for name in keys(local.cp_component_baseline) : local.cp_effective_numeric[name].memory_mib])
      }
      services = {
        cpu_m      = sum([for name in keys(local.cp_budget_defaults) : local.cp_effective_numeric["${name}_reserve"].cpu_m])
        memory_mib = sum([for name in keys(local.cp_budget_defaults) : local.cp_effective_numeric["${name}_reserve"].memory_mib])
      }
      combined = { cpu_m = local.cp_total_cpu_m, memory_mib = local.cp_total_memory_mib }
    }
    required          = { cpu_m = local.cp_required_cpu_m, memory_mib = local.cp_required_memory_mib }
    recommended       = { cpu_m = local.cp_recommended_cpu_m, memory_mib = local.cp_recommended_memory_mib }
    nodes             = local.cp_node_capacity
    fits              = local.cp_capacity_fits
    invalid_resources = local.cp_invalid_resources
    invalid_settings  = local.cp_invalid_settings
  }
}

check "control_plane_recommended_capacity" {
  assert {
    condition     = length(local.cp_oversized_nodes) == 0
    error_message = "Possible control-plane oversizing: ${join(", ", local.cp_oversized_nodes)} exceed the recommended upper size of ${local.cp_recommended_cpu_m / 1000} vCPU / ${local.cp_recommended_memory_mib / 1024}Gi (including ${local.cp_headroom_percent}% free headroom). This is a warning only; VM sizes are unchanged."
  }
}

output "control_plane_sizing" {
  description = "Estimated per-CP requirements, service budgets, worker capacity and deficits; contains no credentials."
  value       = local.control_plane_sizing
}
