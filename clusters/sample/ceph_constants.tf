locals {
  ceph_mode = "internal"
  ceph_namespace    = "rook-ceph"
  ceph_cluster_name = "rook-ceph"
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
    monitors = [
      { id = "a", endpoint = "10.0.0.11:6789" },
      { id = "b", endpoint = "10.0.0.12:6789" },
      { id = "c", endpoint = "10.0.0.13:6789" },
    ]
    fsid                      = ""
    admin_username            = "client.admin"
    admin_secret              = ""
    healthcheck_secret        = ""
  }
}
