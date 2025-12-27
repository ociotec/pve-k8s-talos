locals {
  controlplane_vms = { for k, v in var.vms : k => v if v.type == "controlplane" }
  worker_vms       = { for k, v in var.vms : k => v if v.type == "worker" }
}
