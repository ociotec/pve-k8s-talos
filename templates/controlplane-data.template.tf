data "talos_machine_configuration" "machineconfig___SAFE_NAME__" {
  lifecycle {
    precondition {
      condition = !local.image_unpack_sync_fs || alltrue([
        for f in try(yamldecode(split("\n---\n", file("${path.module}/patches/machine-__NAME__.yaml"))[0]).machine.files, []) :
        try(f.path != "/etc/cri/conf.d/20-customization.part", true)
      ])
      error_message = "image_unpack_sync_fs cannot replace an existing CRI customization. Review and merge its TOML explicitly, or leave the optional setting disabled."
    }
    precondition {
      condition = !local.image_unpack_sync_fs || local.image_unpack_sync_fs_supported
      error_message = "image_unpack_sync_fs requires Talos 1.10 or newer in the supported 1.x series; leave it disabled on older versions."
    }
  }
  cluster_name     = var.constants["talos"]["cluster_name"]
  cluster_endpoint = "https://${try(var.constants["talos"]["controlplane_vip"], local.controlplane_vms["__PRIMARY_CONTROLPLANE__"].ip)}:6443"
  talos_version   = var.constants["talos"]["version"]
  kubernetes_version = try(var.constants["talos"]["kubernetes_version"], "v1.35.0")
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.machine_secrets.machine_secrets
  config_patches = compact([
    local.image_unpack_sync_fs_patch,
    file("${path.module}/patches/machine-__NAME__.yaml"),
    local.network_interface_patches["__NAME__"],
    fileexists("${path.module}/patches/trusted-roots-root-ca.yaml") ? file("${path.module}/patches/trusted-roots-root-ca.yaml") : "",
    file("${path.module}/patches/qemu.yaml"),
  ])
}
