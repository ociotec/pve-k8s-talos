variable "constants" {
  type = any
}

variable "resources" {
  type = map(object({
    vcpus           = number
    memory          = number
    k8s_node        = string
    k8s_labels      = optional(map(string), {})
    machine_sysctls = optional(map(string), {})
    disks = list(object({
      size                  = number
      mount                 = optional(string)
      user_volume           = optional(string)
      project_quota_support = optional(bool, false)
    }))
  }))
  validation {
    condition = alltrue([
      for name, resource in var.resources :
      contains(["controlplane", "worker"], resource.k8s_node)
    ])
    error_message = "Each resources entry must set k8s_node to \"controlplane\" or \"worker\"."
  }
  validation {
    condition = alltrue(flatten([
      for _, resource in var.resources : [
        for key, value in resource.machine_sysctls :
        trimspace(key) != "" && trimspace(value) != ""
      ]
    ]))
    error_message = "machine_sysctls keys and values must be non-empty strings."
  }
  validation {
    condition = alltrue(flatten([
      for _, resource in var.resources : [
        for index, disk in resource.disks :
        index > 0 || disk.user_volume == null || disk.user_volume == ""
      ]
    ]))
    error_message = "The root disk at index 0 cannot define a Talos user_volume."
  }
  validation {
    condition = alltrue(flatten([
      for _, resource in var.resources : [
        for _, disk in resource.disks :
        disk.user_volume == null || disk.user_volume == "" || (
          can(regex("^[A-Za-z0-9-]{1,34}$", disk.user_volume)) &&
          disk.mount != null &&
          startswith(disk.mount, "/var/")
        )
      ]
    ]))
    error_message = "Each Talos user_volume must have a 1-34 character alphanumeric/hyphen name and a mount destination below /var/."
  }
  validation {
    condition = alltrue(flatten([
      for _, resource in var.resources : [
        for _, disk in resource.disks :
        !disk.project_quota_support || (disk.user_volume != null && disk.user_volume != "")
      ]
    ]))
    error_message = "project_quota_support can only be enabled for a Talos user_volume disk."
  }
  validation {
    condition = alltrue([
      for _, resource in var.resources :
      length([for disk in resource.disks : disk.user_volume if disk.user_volume != null && disk.user_volume != ""]) ==
      length(distinct([for disk in resource.disks : disk.user_volume if disk.user_volume != null && disk.user_volume != ""]))
    ])
    error_message = "Talos user_volume names must be unique within each resource profile."
  }
}

variable "vms" {
  type = map(object({
    node_name  = string
    vm_id      = number
    type       = string
    ip         = string
    ip2        = optional(string)
    k8s_labels = optional(map(string), {})
    vm_tags    = optional(string)
  }))
  validation {
    condition = alltrue([
      for name, vm in var.vms :
      contains(keys(var.resources), vm.type)
    ])
    error_message = "Each vms entry must reference a type that exists in var.resources."
  }
}

locals {
  controlplane_vms = { for k, v in var.vms : k => v if var.resources[v.type].k8s_node == "controlplane" }
  worker_vms       = { for k, v in var.vms : k => v if var.resources[v.type].k8s_node == "worker" }
}
