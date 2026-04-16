variable "constants" {
  type = any
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
  validation {
    condition = alltrue([
      for name, resource in var.resources :
      contains(["controlplane", "worker"], resource.k8s_node)
    ])
    error_message = "Each resources entry must set k8s_node to \"controlplane\" or \"worker\"."
  }
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
