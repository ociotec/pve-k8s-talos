locals {
  controlplane_vms = { for k, v in var.vms : k => v if var.resources[v.type].k8s_node == "controlplane" }
  worker_vms       = { for k, v in var.vms : k => v if var.resources[v.type].k8s_node == "worker" }
}
