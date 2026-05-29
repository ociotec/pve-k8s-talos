constants = {
  "vm" = {
    "name"                    = "bootstrap-example"
    "node_name"               = "pve01"
    "vm_id"                   = 9001
    "pool"                    = ""
    "datastore_id"            = "local-lvm"
    "cloudinit_datastore_id"  = "local-lvm"
    "snippets_datastore_id"   = "local"
    "cloud_image_file_id"     = "local:iso/debian-13-generic-amd64.qcow2"
    "cloud_image_import_from" = null
    "started"                 = true
    "operating_system_type"   = "l26"
    "vcpus"                   = 4
    "memory"                  = 8192
    "tags"                    = "debian,bootstrap"
    "disks" = [
      { size = 32 },
      { size = 128 },
    ]
  }

  "network" = {
    "ip"            = "192.0.2.10"
    "net_size"      = "24"
    "gateway"       = "192.0.2.1"
    "dns_servers"   = "192.0.2.53"
    "domain"        = "example.com"
    "bridge_device" = "vmbr0"
    "vlan_tag"      = ""
  }

  "os" = {
    # May be a short hostname or FQDN. The VM keeps the short hostname and cloud-init uses the FQDN.
    "hostname"                  = "bootstrap-example.example.com"
    "username"                  = "debian"
    "user_uid"                  = null
    "user_gid"                  = null
    "ssh_public_keys"           = []
    "ssh_public_key_files"      = []
    "password_hash"             = ""
    "timezone"                  = "UTC"
    "apt_proxy"                 = ""
    "package_update"            = true
    "package_upgrade"           = true
    "reboot_after_provisioning" = true
    # Optional CA files installed into Debian's system trust store.
    "trusted_ca_paths" = []
    "packages" = [
      "vim",
    ]
  }
}
