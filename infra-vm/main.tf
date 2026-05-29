variable "constants" {
  type = any
}

variable "services" {
  type    = any
  default = {}
}

locals {
  vm        = var.constants["vm"]
  network   = var.constants["network"]
  os        = var.constants["os"]
  docker    = try(var.services["docker"], {})
  discovery = try(var.services["talos_discovery"], {})

  vm_name                 = local.vm["name"]
  username                = try(local.os["username"], "debian")
  user_uid                = try(local.os["user_uid"], null) == null ? "" : tostring(local.os["user_uid"])
  user_gid                = try(local.os["user_gid"], null) == null ? "" : tostring(local.os["user_gid"])
  configured_hostname     = try(local.os["hostname"], local.vm_name)
  domain                  = try(local.network["domain"], "local")
  hostname                = split(".", local.configured_hostname)[0]
  fqdn                    = strcontains(local.configured_hostname, ".") ? local.configured_hostname : (local.domain != "" ? "${local.configured_hostname}.${local.domain}" : local.configured_hostname)
  snippets_store          = try(local.vm["snippets_datastore_id"], "local")
  cloudinit_store         = try(local.vm["cloudinit_datastore_id"], local.vm["datastore_id"])
  cloud_image_file_id     = try(local.vm["cloud_image_file_id"], null)
  cloud_image_import_from = try(local.vm["cloud_image_import_from"], null)
  vlan_tag                = try(local.network["vlan_tag"], "")
  pool_id                 = try(local.vm["pool"], "")
  extra_vm_tags           = [for tag in split(",", try(local.vm["tags"], "")) : trimspace(tag) if trimspace(tag) != ""]
  disks                   = try(local.vm["disks"], [{ size = 32 }])
  extra_disks             = length(local.disks) > 1 ? slice(local.disks, 1, length(local.disks)) : []

  docker_enabled    = try(local.docker["enabled"], true)
  discovery_enabled = try(local.discovery["enabled"], true)
  docker_registry_mirrors = [
    for endpoint in try(local.docker["registry_mirrors"], []) :
    endpoint
    if trimspace(endpoint) != ""
  ]
  docker_insecure_registries = [
    for registry in try(local.docker["insecure_registries"], []) :
    registry
    if trimspace(registry) != ""
  ]
  docker_registry_auths = try(local.docker["registry_auths"], {})
  docker_daemon_config = merge(
    length(local.docker_registry_mirrors) > 0 ? { "registry-mirrors" = local.docker_registry_mirrors } : {},
    length(local.docker_insecure_registries) > 0 ? { "insecure-registries" = local.docker_insecure_registries } : {},
    try(local.docker["daemon_options"], {}),
  )
  docker_auth_config = {
    auths = {
      for registry, auth in local.docker_registry_auths :
      registry => {
        auth = base64encode("${auth.username}:${auth.password}")
      }
    }
  }

  ssh_public_key_file_paths = [
    for key_path in try(local.os["ssh_public_key_files"], []) :
    startswith(key_path, "/") || startswith(key_path, "~") ? pathexpand(key_path) : "${path.module}/${key_path}"
  ]
  ssh_public_keys = distinct(compact(concat(
    try(local.os["ssh_public_keys"], []),
    [
      for key_path in local.ssh_public_key_file_paths :
      trimspace(file(key_path))
      if fileexists(key_path)
    ],
  )))
  trusted_ca_paths = try(local.os["trusted_ca_paths"], [])
  trusted_ca_certificates = [
    for ca_path in local.trusted_ca_paths : {
      source_path = ca_path
      name        = replace(basename(ca_path), "/\\.(pem|crt|cer)$/", ".crt")
      content     = fileexists("${path.module}/${ca_path}") ? file("${path.module}/${ca_path}") : ""
    }
  ]

  base_packages = [
    "ca-certificates",
    "curl",
    "gnupg",
    "jq",
    "openssl",
    "qemu-guest-agent",
  ]
  docker_packages    = local.docker_enabled ? try(local.docker["packages"], ["docker.io"]) : []
  discovery_packages = local.discovery_enabled ? ["nginx"] : []
  packages = distinct(concat(
    local.base_packages,
    try(local.os["packages"], []),
    local.docker_packages,
    local.discovery_packages,
  ))

  discovery_tls_cert_path = try(local.discovery["tls_cert_path"], "")
  discovery_tls_key_path  = try(local.discovery["tls_key_path"], "")
  discovery_tls_cert = (
    local.discovery_enabled && local.discovery_tls_cert_path != "" && fileexists("${path.module}/${local.discovery_tls_cert_path}")
    ? file("${path.module}/${local.discovery_tls_cert_path}")
    : ""
  )
  discovery_tls_key = (
    local.discovery_enabled && local.discovery_tls_key_path != "" && fileexists("${path.module}/${local.discovery_tls_key_path}")
    ? file("${path.module}/${local.discovery_tls_key_path}")
    : ""
  )
  discovery_env_lines = [
    for key, value in try(local.discovery["environment"], {}) :
    "${key}=${value}"
  ]

  cloud_init_user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname                   = local.hostname
    fqdn                       = local.fqdn
    timezone                   = try(local.os["timezone"], "UTC")
    username                   = local.username
    user_uid                   = local.user_uid
    user_gid                   = local.user_gid
    ssh_public_keys            = local.ssh_public_keys
    password_hash              = try(local.os["password_hash"], "")
    apt_proxy                  = try(local.os["apt_proxy"], "")
    package_update             = try(local.os["package_update"], true)
    package_upgrade            = try(local.os["package_upgrade"], true)
    reboot_after_provisioning  = try(local.os["reboot_after_provisioning"], true)
    packages                   = local.packages
    trusted_ca_certificates    = local.trusted_ca_certificates
    docker_enabled             = local.docker_enabled
    docker_daemon_json         = length(keys(local.docker_daemon_config)) > 0 ? jsonencode(local.docker_daemon_config) : ""
    docker_auth_config_json    = length(keys(local.docker_registry_auths)) > 0 ? jsonencode(local.docker_auth_config) : ""
    discovery_enabled          = local.discovery_enabled
    discovery_image            = try(local.discovery["image"], "ghcr.io/siderolabs/discovery-service:v1.0.17")
    discovery_pull_policy      = try(local.discovery["pull_policy"], "missing")
    discovery_grpc_port        = try(local.discovery["grpc_port"], 3000)
    discovery_http_port        = try(local.discovery["http_port"], 3001)
    discovery_public_port      = try(local.discovery["public_port"], 443)
    discovery_server_name      = try(local.discovery["server_name"], local.fqdn)
    discovery_tls_cert         = local.discovery_tls_cert
    discovery_tls_key          = local.discovery_tls_key
    discovery_env_file_content = join("\n", local.discovery_env_lines)
  })
}

resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  content_type = "snippets"
  datastore_id = local.snippets_store
  node_name    = local.vm["node_name"]

  source_raw {
    data      = local.cloud_init_user_data
    file_name = "${local.vm_name}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "infra_vm" {
  name      = local.vm_name
  node_name = local.vm["node_name"]
  vm_id     = local.vm["vm_id"]
  # Infra VMs may be broken mid-boot; destroy should use a Proxmox stop, not a guest shutdown.
  stop_on_destroy = true
  started         = try(local.vm["started"], true)
  pool_id         = local.pool_id != "" ? local.pool_id : null
  tags            = distinct(concat(["infra-vm", "bootstrap"], local.extra_vm_tags))

  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores = local.vm["vcpus"]
    type  = "host"
  }

  operating_system {
    type = try(local.vm["operating_system_type"], "l26")
  }

  serial_device {
    device = "socket"
  }

  memory {
    dedicated = local.vm["memory"]
  }

  network_device {
    bridge  = local.network["bridge_device"]
    model   = "virtio"
    vlan_id = local.vlan_tag != "" ? tonumber(local.vlan_tag) : null
  }

  disk {
    datastore_id = local.vm["datastore_id"]
    file_id      = local.cloud_image_file_id
    import_from  = local.cloud_image_import_from
    interface    = "scsi0"
    size         = local.disks[0].size
    ssd          = true
    discard      = "on"
    cache        = "writethrough"
  }

  dynamic "disk" {
    for_each = local.extra_disks
    content {
      datastore_id = local.vm["datastore_id"]
      interface    = "scsi${disk.key + 1}"
      size         = disk.value.size
      ssd          = true
      discard      = "on"
      cache        = "writethrough"
    }
  }

  initialization {
    datastore_id      = local.cloudinit_store
    user_data_file_id = proxmox_virtual_environment_file.user_data_cloud_config.id

    ip_config {
      ipv4 {
        address = "${local.network["ip"]}/${local.network["net_size"]}"
        gateway = local.network["gateway"]
      }
    }

    dns {
      domain = local.domain
      servers = [
        for server in split(",", local.network["dns_servers"]) :
        trimspace(server)
        if trimspace(server) != ""
      ]
    }
  }

  lifecycle {
    precondition {
      condition     = local.cloud_image_file_id != null || local.cloud_image_import_from != null
      error_message = "Set either vm.cloud_image_file_id or vm.cloud_image_import_from to a Debian cloud image available to Proxmox."
    }
    precondition {
      condition     = !(local.cloud_image_file_id != null && local.cloud_image_import_from != null)
      error_message = "Set only one of vm.cloud_image_file_id or vm.cloud_image_import_from."
    }
    precondition {
      condition     = local.user_uid == "" || can(regex("^[0-9]+$", local.user_uid))
      error_message = "os.user_uid must be empty or a numeric UID."
    }
    precondition {
      condition     = local.user_gid == "" || can(regex("^[0-9]+$", local.user_gid))
      error_message = "os.user_gid must be empty or a numeric GID."
    }
    precondition {
      condition     = !(local.discovery_enabled && local.discovery_tls_cert_path != "" && !fileexists("${path.module}/${local.discovery_tls_cert_path}"))
      error_message = "services.talos_discovery.tls_cert_path is set but the file does not exist in the infra-vm workspace."
    }
    precondition {
      condition     = !(local.discovery_enabled && local.discovery_tls_key_path != "" && !fileexists("${path.module}/${local.discovery_tls_key_path}"))
      error_message = "services.talos_discovery.tls_key_path is set but the file does not exist in the infra-vm workspace."
    }
    precondition {
      condition     = !(local.discovery_enabled && ((local.discovery_tls_cert_path == "") != (local.discovery_tls_key_path == "")))
      error_message = "Set both services.talos_discovery.tls_cert_path and tls_key_path, or leave both empty for a generated self-signed certificate."
    }
    precondition {
      condition = alltrue([
        for key_path in local.ssh_public_key_file_paths :
        fileexists(key_path)
      ])
      error_message = "Every os.ssh_public_key_files entry must point to a readable public key file. Absolute paths and ~/ paths are supported; relative paths are resolved from the infra-vm workspace."
    }
    precondition {
      condition = alltrue([
        for ca_path in local.trusted_ca_paths :
        fileexists("${path.module}/${ca_path}")
      ])
      error_message = "Every os.trusted_ca_paths entry must point to a readable CA file in the infra-vm workspace."
    }
    precondition {
      condition = alltrue([
        for endpoint in local.docker_registry_mirrors :
        can(regex("^https?://", endpoint))
      ])
      error_message = "Every services.docker.registry_mirrors entry must be a full http:// or https:// URL."
    }
  }
}

output "infra_vm_name" {
  value = proxmox_virtual_environment_vm.infra_vm.name
}

output "infra_vm_ip" {
  value = local.network["ip"]
}

output "talos_discovery_endpoint" {
  value = local.discovery_enabled ? "https://${try(local.discovery["server_name"], local.fqdn)}:${try(local.discovery["public_port"], 443)}" : null
}
