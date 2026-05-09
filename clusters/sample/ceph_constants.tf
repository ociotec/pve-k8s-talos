locals {
  ceph_mode          = "internal"
  ceph_namespace     = "rook-ceph"
  ceph_cluster_name  = "rook-ceph"
  ceph_cluster_image = "quay.io/ceph/ceph:v20.2.1"

  ceph_name_prefix = "sample"

  ceph_block_replicated = {
    enabled  = true
    size     = 3
    min_size = 2
    pg_num   = 32
  }

  ceph_block_ec = {
    enabled           = true
    k                 = 2
    m                 = 1
    metadata_size     = 3
    metadata_min_size = 2
    pg_num            = 32
  }

  ceph_filesystem_replicated = {
    enabled                        = true
    size                           = 3
    min_size                       = 2
    metadata_server_active_count   = 1
    metadata_server_active_standby = true
    preserve_filesystem_on_delete  = true
  }

  ceph_filesystem_ec = {
    enabled                        = true
    metadata_size                  = 3
    metadata_min_size              = 2
    default_data_size              = 3
    default_data_min_size          = 2
    k                              = 2
    m                              = 1
    metadata_server_active_count   = 1
    metadata_server_active_standby = true
    preserve_filesystem_on_delete  = true
  }

  # Values below are ignored in internal mode. Keep all external-cluster data here so
  # the Ceph scope still uses a single constants file per cluster.
  ceph_external = {
    # Optional SSH host/IP for Ceph CLI operations such as erasure-coded RBD pool creation.
    # Leave empty to use the first monitor endpoint without its port.
    # Example: "192.0.2.11"
    ssh_host = ""

    # On a PVE Ceph node as root, list monitor IDs and v1 endpoints with:
    # ceph mon dump
    # Use each mon name as id and its v1 address without the trailing /rank, for example 10.0.0.11:6789.
    # If jq is available:
    # ceph mon dump -f json | jq -r '.mons[] | .name as $id | (.public_addrs.addrvec[] | select(.type == "v1").addr | sub("/.*$"; "")) as $addr | "      { id = \"\($id)\", endpoint = \"\($addr)\" },"'
    monitors = [
      { id = "a", endpoint = "10.0.0.11:6789" },
      { id = "b", endpoint = "10.0.0.12:6789" },
      { id = "c", endpoint = "10.0.0.13:6789" },
    ]

    # Optional ceph-mgr Prometheus endpoints for external Ceph pool/PG dashboards.
    # On a Ceph node or from rook-ceph-tools:
    # ceph mgr services -f json
    # Use host:port targets without scheme; set prometheus_scheme if the mgr endpoint uses HTTPS.
    # List every mgr endpoint when possible; standby mgrs may return empty scrapes until failover.
    prometheus_scheme = "http"
    prometheus_targets = [
      "10.0.0.11:9283",
      "10.0.0.12:9283",
      "10.0.0.13:9283",
    ]

    # On a PVE Ceph node as root:
    # ceph fsid
    fsid = ""

    # Use client.admin when Rook must create or reconcile external Ceph pools/filesystems.
    # To inspect the configured admin identity:
    # ceph auth get client.admin
    admin_username = "client.admin"

    # On a PVE Ceph node as root:
    # ceph auth get-key client.admin
    # This is required when external CephFS resources are enabled or when Rook must manage pools/filesystems.
    admin_secret = ""

    # On a PVE Ceph node as root:
    # ceph auth get-or-create-key client.healthchecker mon 'allow r'
    # Used only when admin_secret is empty; it is sufficient for basic external cluster health checks.
    healthcheck_secret = ""
  }
}
