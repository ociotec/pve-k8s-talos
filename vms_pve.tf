resource "proxmox_virtual_environment_vm" "create_pve_vms" {
  for_each = var.vms

  name            = each.key
  node_name       = each.value.node_name
  vm_id           = each.value.vm_id
  stop_on_destroy = true # Stop VM before destroying if QEMU is not deployed
  started         = true # Do or do not start VM after creation
  pool_id         = "kubernetes"

  agent {
    enabled = true
    trim    = true
  }
  tags = ["server", "k8s", "talos", each.value.type]

  cpu {
    cores = var.resources[each.value.type].vcpus
    type  = "host"
  }
  memory {
    dedicated = var.resources[each.value.type].memory # Memory in MB
  }
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }
  dynamic "disk" {
    for_each = var.resources[each.value.type].disks
    content {
      datastore_id = "local-lvm"
      interface    = "scsi${disk.key}"
      size         = disk.value # Size in GB
      ssd          = true
      discard      = "on"
      cache        = "writethrough"
    }
  }
  cdrom {
    interface = "sata0"
    file_id   = var.constants["vm"]["iso_path"]
  }
  boot_order = ["scsi0", "sata0"]

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.constants["network"]["net_size"]}"
        gateway = var.constants["network"]["gateway"]
      }
    }
    dns {
      domain  = "local"
      servers = [var.constants["network"]["dns1"], var.constants["network"]["dns2"]]
    }
  }
}
