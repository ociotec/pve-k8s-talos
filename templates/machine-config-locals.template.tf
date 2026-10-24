locals {
  # Opt-in: forcing a filesystem sync trades image unpack speed for durability.
  # Existing clusters retain their configuration until explicitly enabled.
  image_unpack_sync_fs = try(tobool(var.constants["talos"]["image_unpack_sync_fs"]), false)
  talos_version_parts = split(".", trimprefix(var.constants["talos"]["version"], "v"))
  image_unpack_sync_fs_supported = alltrue([tonumber(local.talos_version_parts[0]) == 1, tonumber(local.talos_version_parts[1]) >= 10])
  image_unpack_sync_fs_content = "[plugins.\"io.containerd.service.v1.diff-service\"]\n  sync_fs = true\n"
  # This legacy path is explicitly supported in 1.10-1.14 (a compatibility
  # shim on 1.14). Arbitrary new files under /etc cannot be created by machine.files.
  # Per-node preconditions reject existing customization instead of replacing it.
  image_unpack_sync_fs_patch = !local.image_unpack_sync_fs ? "" : yamlencode({
    machine = {
      files = [{
        path        = "/etc/cri/conf.d/20-customization.part"
        op          = "create"
        permissions = 384 # 0600; create is idempotent and also works when the file is absent.
        content     = local.image_unpack_sync_fs_content
      }]
    }
  })
  controlplane_machine_config = {
__CONTROLPLANE_LOCALS__
  }
  worker_machine_config = {
__WORKER_LOCALS__
  }
  all_machine_config = merge(local.controlplane_machine_config, local.worker_machine_config)
}
