locals {
  extra_vm_tags = [
    for tag in split(",", var.constants["vm"]["tags"]) :
    trimspace(tag)
    if trimspace(tag) != ""
  ]
  hotplug_enabled = var.constants["vm"]["hotplug"] != ""
  hotplug_features = [
    for feature in split(",", var.constants["vm"]["hotplug"]) :
    lower(trimspace(feature))
    if trimspace(feature) != ""
  ]
  hotplug_has_mem = contains(local.hotplug_features, "memory")
}

resource "proxmox_virtual_environment_vm" "create_pve_vms" {
  for_each = var.vms

  name            = each.key
  node_name       = each.value.node_name
  vm_id           = each.value.vm_id
  stop_on_destroy = true # Stop VM before destroying if QEMU is not deployed
  started         = false # Start VMs after hotplug is configured
  pool_id         = var.constants["vm"]["pool"] != "" ? var.constants["vm"]["pool"] : null
  agent {
    enabled = true
    trim    = true
  }
  tags = distinct(concat(
    [var.resources[each.value.type].k8s_node, each.value.type],
    local.extra_vm_tags
  ))

  cpu {
    cores = var.resources[each.value.type].vcpus
    type  = "host"
  }
  memory {
    dedicated = var.resources[each.value.type].memory # Memory in MB
  }
  network_device {
    bridge  = "vmbr0"
    model   = "virtio"
    vlan_id = var.constants["network"]["vlan_tag"] != "" ? tonumber(var.constants["network"]["vlan_tag"]) : null
  }
  dynamic "disk" {
    for_each = var.resources[each.value.type].disks
    content {
      datastore_id = var.constants["vm"]["datastore_id"]
      interface    = "scsi${disk.key}"
      size         = disk.value.size # Size in GB
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
    datastore_id = var.constants["vm"]["datastore_id"]
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.constants["network"]["net_size"]}"
        gateway = var.constants["network"]["gateway"]
      }
    }
    dns {
      domain  = "local"
      servers = [
        for server in split(",", var.constants["network"]["dns_servers"]) :
        trimspace(server)
        if trimspace(server) != ""
      ]
    }
  }
}

resource "null_resource" "proxmox_hotplug" {
  // Runs only when an endpoint is set and hotplug is non-empty.
  for_each = local.hotplug_enabled ? var.vms : {}

  // Ensure VMs exist before configuring hotplug.
  depends_on = [proxmox_virtual_environment_vm.create_pve_vms]

  triggers = {
    node    = each.value.node_name
    vm_id   = tostring(each.value.vm_id)
    hotplug = var.constants["vm"]["hotplug"]
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    on_failure  = "fail"
    command = "${path.module}/scripts/pve-api.sh set-hotplug --node ${each.value.node_name} --vmid ${each.value.vm_id} --hotplug ${var.constants["vm"]["hotplug"]}${local.hotplug_has_mem ? " --enable-numa" : ""}"
  }
}

resource "null_resource" "proxmox_start_vms" {
  // Start VMs after hotplug configuration completes.
  for_each = local.hotplug_enabled ? var.vms : {}

  depends_on = [null_resource.proxmox_hotplug]

  triggers = {
    node  = each.value.node_name
    vm_id = tostring(each.value.vm_id)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    on_failure  = "fail"
    command = "${path.module}/scripts/pve-api.sh start-vm --node ${each.value.node_name} --vmid ${each.value.vm_id}"
  }
}

resource "null_resource" "all_vms_ready" {
  // Final sync point for all VM creation/configuration steps.
  depends_on = [
    proxmox_virtual_environment_vm.create_pve_vms,
    null_resource.proxmox_hotplug,
    null_resource.proxmox_start_vms,
  ]
}

output "all_vms_ready" {
  value = null_resource.all_vms_ready.id
}
