locals {
  extra_vm_tags = [
    for tag in split(",", var.constants["vm"]["tags"]) :
    trimspace(tag)
    if trimspace(tag) != ""
  ]
  pve_network2_enabled = try(trimspace(var.constants["network2"]["bridge_device"]) != "", false)
}

resource "proxmox_virtual_environment_vm" "create_pve_vms" {
  for_each = var.vms

  lifecycle {
    precondition {
      condition     = length(local.cp_invalid_settings) == 0
      error_message = "Invalid control-plane sizing settings: ${join(", ", local.cp_invalid_settings)}. max_pods must be an integer from 1 to 65535; control_plane_recommended_headroom_percent must be an integer from 0 to 99. Empty values select defaults."
    }
    precondition {
      condition     = length(local.cp_invalid_resources) == 0
      error_message = "Invalid control-plane resource pairs: ${join(", ", local.cp_invalid_resources)}. Set both CPU and memory or neither, using canonical Kubernetes quantities."
    }
    precondition {
      # The guarded bootstrap rejects all CPU/RAM edits before applying its plan.
      condition     = var.bootstrap_secondary_network || var.allow_control_plane_overcommit || local.cp_capacity_fits
      error_message = "Control-plane capacity is insufficient. Each CP needs at least ${local.cp_required_cpu_m / 1000} vCPU and ${local.cp_required_memory_mib / 1024}Gi RAM including service budgets, without percentage headroom. Review output control_plane_sizing; deploy.sh --force-control-plane-capacity bypasses only this gate."
    }
  }

  name            = each.key
  node_name       = each.value.node_name
  vm_id           = each.value.vm_id
  stop_on_destroy = true # Stop VM before destroying if QEMU is not deployed
  started         = true # Do or do not start VM after creation
  # deploy.sh shuts down and resizes existing CPs one at a time. Never let the
  # provider reboot several CPs during a bulk root apply, including network edits.
  # Worker CPU/RAM increases also finish sequentially before the bulk apply.
  reboot_after_update = !var.bootstrap_secondary_network && var.resources[each.value.type].k8s_node != "controlplane"
  pool_id         = var.constants["vm"]["pool"] != "" ? var.constants["vm"]["pool"] : null
  agent {
    enabled = true
    trim    = true
  }
  tags = distinct(concat(
    [var.resources[each.value.type].k8s_node, each.value.type],
    local.extra_vm_tags,
    [
      for tag in split(",", try(each.value.vm_tags != null ? each.value.vm_tags : "", "")) :
      trimspace(tag)
      if trimspace(tag) != ""
    ]
  ))

  cpu {
    cores = var.resources[each.value.type].vcpus
    type  = "host"
  }
  memory {
    dedicated = var.resources[each.value.type].memory # Memory in MB
  }
  network_device {
    bridge  = var.constants["network"]["bridge_device"]
    model   = "virtio"
    vlan_id = var.constants["network"]["vlan_tag"] != "" ? tonumber(var.constants["network"]["vlan_tag"]) : null
  }
  dynamic "network_device" {
    for_each = local.pve_network2_enabled && trimspace(try(each.value.ip2 != null ? each.value.ip2 : "", "")) != "" ? [var.constants["network2"]] : []
    content {
      bridge  = network_device.value["bridge_device"]
      model   = "virtio"
      vlan_id = try(trimspace(network_device.value["vlan_tag"]) != "" ? tonumber(network_device.value["vlan_tag"]) : null, null)
    }
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

  # Unlock VM before destroying it (avoids "VM is locked" errors during destroy).
  provisioner "local-exec" {
    when = destroy
    command = <<-EOT
      set -e
      if [ -n "$${PROXMOX_VE_API_TOKEN:-}" ] && [ -n "$${PROXMOX_VE_ENDPOINT:-}" ]; then
        endpoint="$${PROXMOX_VE_ENDPOINT%/}"
        insecure_flag=""
        if [ "$${PROXMOX_VE_INSECURE:-}" = "true" ]; then
          insecure_flag="--insecure"
        fi

        # Try unlocking; ignore failures (already unlocked, already deleted, etc.)
        curl $${insecure_flag} --silent --show-error --fail \
          --request POST \
          --header "Authorization: PVEAPIToken $${PROXMOX_VE_API_TOKEN}" \
          "$${endpoint}/api2/json/nodes/${self.node_name}/qemu/${self.vm_id}/unlock" \
          || true
      fi
    EOT
  }
}

resource "null_resource" "all_vms_ready" {
  // Final sync point for all VM creation/configuration steps.
  depends_on = [
    proxmox_virtual_environment_vm.create_pve_vms,
  ]
}

output "all_vms_ready" {
  value = null_resource.all_vms_ready.id
}
