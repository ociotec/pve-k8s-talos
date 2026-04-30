constants = {
  # These are example values, update them to match your environment
  "vm" = {
    "iso_path"          = "ceph-fs:iso/talos-v1.12.6-nocloud-amd64-with-qemu-guest-agent.iso"
    "datastore_id"      = "local-lvm"
    # Proxmox pool name for VM placement (leave empty to disable).
    "pool"              = ""
    # Prefix for /dev/disk/by-id (rarely needs changes in typical Proxmox setups).
    # Example: scsi-0QEMU_QEMU_HARDDISK_drive-scsi
    "disk_by_id_prefix" = "scsi-0QEMU_QEMU_HARDDISK_drive-scsi"
    # Comma-separated list of extra VM tags (example: "prod,ceph,kafka").
    "tags"              = "talos,k8s,server"
  }
  "network" = {
    "net_size"           = "24"
    "gateway"            = "192.168.1.1"
    "dns_servers"        = "80.58.61.250,80.58.61.254"
    # Optional comma-separated DNS server IPs for the Talos kernel ip= argument.
    # Leave empty to reuse the first entries from dns_servers when proxy_url uses a hostname.
    # Example: "192.168.1.10,192.168.1.11"
    "kernel_dns_servers" = ""
    # Disable IPv6 at kernel level for Talos nodes. Set to "false" to keep IPv6 enabled.
    "disable_ipv6"       = "true"
    # Optional corporate proxy URL reused for both Talos http_proxy and https_proxy.
    # When this uses a hostname, the generator also adds Talos kernel args so early stages
    # can resolve the proxy with kernel DNS servers.
    # Example: http://proxy.example.com:3128/
    "proxy_url"          = ""
    # Optional extra comma-separated no_proxy entries appended after the auto-generated
    # localhost, node IPs, local subnet, k8s service names, and ingress hostnames.
    "no_proxy_extra"     = ""
    # Optional comma-separated PEM certificate paths appended to Talos trust roots.
    # Use this for extra CAs such as TLS-intercepting proxy certificates.
    # The main cluster root CA should be set with root_ca_crt in k8s_net_constants.tf.
    # Example: "./certs/company-proxy-ca.pem,./certs/internal-root-ca.pem"
    "cert_files"         = ""
    # Proxmox bridge device name (example: vmbr0).
    "bridge_device"      = "vmbr0"
    # Leave empty to disable
    "vlan_tag"           = ""
    # Comma-separated list, leave empty to disable
    "ntp_servers"        = ""
  }
  "talos" = {
    # Generate new ISO & Talos factory image IDs from https://factory.talos.dev/
    "version"                    = "v1.12.6"
    # Keep this compatible with your Talos version.
    "kubernetes_version"         = "v1.36.0"
    "factory_image_id"           = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
    "cluster_name"               = "talos"
    # Optional kubelet max pods per node. Leave empty to keep Kubernetes default (110).
    "max_pods"                   = ""
    # Optional Talos registry mirror settings. The generator renders these under
    # machine.registries using the global defaults below for every mirror.
    # Example:
    # "registry" = {
    #   "mirrors" = {
    #     "docker.io" = "https://registry.example.com"
    #     "*"         = "https://registry.example.com"
    #   }
    #   "skip_fallback"   = "true"
    #   "override_path"   = "false"
    #   "ignore_TLS_error" = "false"
    # }
    # Disable Talos public discovery service by default. Set to "false" if you
    # explicitly want the external discovery registry (for example with KubeSpan).
    "discovery_service_disabled" = "true"
  }
  "k8s" = {
    "labels" = {}
  }
}
