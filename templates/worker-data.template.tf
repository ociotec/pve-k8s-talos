data "talos_machine_configuration" "machineconfig___SAFE_NAME__" {
  cluster_name     = var.constants["talos"]["cluster_name"]
  cluster_endpoint = "https://${local.controlplane_vms["__PRIMARY_CONTROLPLANE__"].ip}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.machine_secrets.machine_secrets
  config_patches = [
    "${path.module}/patches/network-__NAME__.yaml",
    "${path.module}/patches/disable-aslr.yaml",
    "${path.module}/patches/qemu.yaml",
  ]
}
