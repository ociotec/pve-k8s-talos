terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
  }
}

variable "kubeconfig_path" {
  type    = string
  default = "../../kubeconfig"
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

locals {
  effective_ceph_mode          = try(local.ceph_mode, "internal")
  effective_ceph_namespace     = try(local.ceph_namespace, "rook-ceph")
  effective_ceph_cluster_name  = try(local.ceph_cluster_name, "rook-ceph")
  effective_ceph_cluster_image = try(local.ceph_cluster_image, "quay.io/ceph/ceph:v20.2.1")
  effective_ceph_name_prefix   = try(local.ceph_name_prefix, "cluster")

  external_ceph     = try(local.ceph_external, {})
  external_monitors = try(local.external_ceph.monitors, [])
  external_monitors_normalized = [
    for monitor in local.external_monitors : {
      id       = startswith(monitor.id, "mon.") ? substr(monitor.id, 4, length(monitor.id) - 4) : monitor.id
      endpoint = monitor.endpoint
    }
  ]
  external_mon_data = join(",", [for monitor in local.external_monitors_normalized : format("%s=%s", monitor.id, monitor.endpoint)])
  external_mon_mapping = jsonencode({
    node = {
      for monitor in local.external_monitors_normalized : monitor.id => {
        Name     = split(":", monitor.endpoint)[0]
        Hostname = split(":", monitor.endpoint)[0]
        Address  = split(":", monitor.endpoint)[0]
      }
    }
  })
  external_csi_cluster_config = jsonencode([
    {
      clusterID = local.effective_ceph_namespace
      monitors  = [for monitor in local.external_monitors_normalized : monitor.endpoint]
      namespace = ""
    }
  ])
  external_ceph_username = trimspace(try(local.external_ceph.admin_secret, "")) != "" ? try(local.external_ceph.admin_username, "client.admin") : try(local.external_ceph.healthcheck_username, "client.healthchecker")
  external_ceph_secret   = trimspace(try(local.external_ceph.admin_secret, "")) != "" ? try(local.external_ceph.admin_secret, "") : try(local.external_ceph.healthcheck_secret, "")
  external_ceph_ssh_host = trimspace(try(local.external_ceph.ssh_host, "")) != "" ? trimspace(local.external_ceph.ssh_host) : regexreplace(try(local.external_monitors[0].endpoint, ""), ":[0-9]+$", "")

  block_replicated = merge(
    {
      enabled   = false
      pool_name = "${local.effective_ceph_name_prefix}-rbd-replica"
      pg_num    = 128
      size      = 3
      min_size  = 2
    },
    try(local.ceph_block_replicated, {})
  )
  block_ec = merge(
    {
      enabled            = false
      pool_name          = "${local.effective_ceph_name_prefix}-rbd-ec"
      data_pool_name     = "${local.effective_ceph_name_prefix}-rbd-ec-data"
      metadata_pool_name = "${local.effective_ceph_name_prefix}-rbd-ec-metadata"
      pg_num             = 128
      metadata_size      = 3
      metadata_min_size  = 2
      k                  = 2
      m                  = 1
    },
    try(local.ceph_block_ec, {})
  )
  block_ec_data_size     = try(local.block_ec.data_size, local.block_ec.k + local.block_ec.m)
  block_ec_data_min_size = try(local.block_ec.data_min_size, local.block_ec.k)

  filesystem_replicated = merge(
    {
      enabled            = false
      filesystem_name    = "${local.effective_ceph_name_prefix}-cephfs-replica"
      metadata_pool_name = "${local.effective_ceph_name_prefix}-cephfs-replica-metadata"
      data_pool_name     = "${local.effective_ceph_name_prefix}-cephfs-replica-data"
      metadata_pg_num    = 16
      data_pg_num        = 128
      size               = 3
      min_size           = 2
    },
    try(local.ceph_filesystem_replicated, {})
  )
  filesystem_ec = merge(
    {
      enabled                = false
      filesystem_name        = "${local.effective_ceph_name_prefix}-cephfs-ec"
      metadata_pool_name     = "${local.effective_ceph_name_prefix}-cephfs-ec-metadata"
      default_data_pool_name = "${local.effective_ceph_name_prefix}-cephfs-ec-default"
      ec_data_pool_name      = "${local.effective_ceph_name_prefix}-cephfs-ec-data"
      metadata_pg_num        = 16
      default_data_pg_num    = 128
      ec_data_pg_num         = 128
      metadata_size          = 3
      metadata_min_size      = 2
      default_data_size      = 3
      default_data_min_size  = 2
      k                      = 2
      m                      = 1
    },
    try(local.ceph_filesystem_ec, {})
  )
  filesystem_ec_data_size     = try(local.filesystem_ec.ec_data_size, local.filesystem_ec.k + local.filesystem_ec.m)
  filesystem_ec_data_min_size = try(local.filesystem_ec.ec_data_min_size, local.filesystem_ec.k)

  external_block_pools = local.effective_ceph_mode == "external" ? merge(
    try(local.block_replicated.enabled, false) ? {
      (local.block_replicated.pool_name) = {
        name     = local.block_replicated.pool_name
        type     = "replicated"
        pg_num   = local.block_replicated.pg_num
        size     = local.block_replicated.size
        min_size = local.block_replicated.min_size
      }
    } : {},
    try(local.block_ec.enabled, false) ? {
      (local.block_ec.metadata_pool_name) = {
        name     = local.block_ec.metadata_pool_name
        type     = "replicated"
        pg_num   = local.block_ec.pg_num
        size     = local.block_ec.metadata_size
        min_size = local.block_ec.metadata_min_size
      }
      (local.block_ec.data_pool_name) = {
        name     = local.block_ec.data_pool_name
        type     = "ec"
        pg_num   = local.block_ec.pg_num
        size     = local.block_ec_data_size
        min_size = local.block_ec_data_min_size
        k        = local.block_ec.k
        m        = local.block_ec.m
      }
    } : {}
  ) : {}

  external_filesystems = local.effective_ceph_mode == "external" ? merge(
    try(local.filesystem_replicated.enabled, false) ? {
      (local.filesystem_replicated.filesystem_name) = {
        name              = local.filesystem_replicated.filesystem_name
        type              = "replicated"
        metadata_pool     = local.filesystem_replicated.metadata_pool_name
        metadata_pg_num   = local.filesystem_replicated.metadata_pg_num
        metadata_size     = local.filesystem_replicated.size
        metadata_min_size = local.filesystem_replicated.min_size
        data_pool         = local.filesystem_replicated.data_pool_name
        data_pg_num       = local.filesystem_replicated.data_pg_num
        data_size         = local.filesystem_replicated.size
        data_min_size     = local.filesystem_replicated.min_size
      }
    } : {},
    try(local.filesystem_ec.enabled, false) ? {
      (local.filesystem_ec.filesystem_name) = {
        name              = local.filesystem_ec.filesystem_name
        type              = "ec"
        metadata_pool     = local.filesystem_ec.metadata_pool_name
        metadata_pg_num   = local.filesystem_ec.metadata_pg_num
        metadata_size     = local.filesystem_ec.metadata_size
        metadata_min_size = local.filesystem_ec.metadata_min_size
        data_pool         = local.filesystem_ec.default_data_pool_name
        data_pg_num       = local.filesystem_ec.default_data_pg_num
        data_size         = local.filesystem_ec.default_data_size
        data_min_size     = local.filesystem_ec.default_data_min_size
        ec_data_pool      = local.filesystem_ec.ec_data_pool_name
        ec_data_pg_num    = local.filesystem_ec.ec_data_pg_num
        ec_data_size      = local.filesystem_ec_data_size
        ec_data_min_size  = local.filesystem_ec_data_min_size
        k                 = local.filesystem_ec.k
        m                 = local.filesystem_ec.m
      }
    } : {}
  ) : {}

  internal_cluster = yamldecode(file("${path.module}/../manifests/cluster.yaml"))
  internal_cluster_manifest = merge(local.internal_cluster, {
    metadata = merge(try(local.internal_cluster.metadata, {}), {
      name      = local.effective_ceph_cluster_name
      namespace = local.effective_ceph_namespace
    })
    spec = merge(local.internal_cluster.spec, {
      cephVersion = merge(try(local.internal_cluster.spec.cephVersion, {}), {
        image = local.effective_ceph_cluster_image
      })
    })
  })

  external_cluster_manifest = {
    apiVersion = "ceph.rook.io/v1"
    kind       = "CephCluster"
    metadata = {
      name      = local.effective_ceph_cluster_name
      namespace = local.effective_ceph_namespace
    }
    spec = {
      external = {
        enable = true
      }
      dataDirHostPath = "/var/lib/rook"
      cephVersion = {
        image = local.effective_ceph_cluster_image
      }
      monitoring = {
        enabled         = false
        metricsDisabled = false
      }
    }
  }
}

check "ceph_mode_valid" {
  assert {
    condition     = contains(["internal", "external"], local.effective_ceph_mode)
    error_message = format("ceph_mode must be \"internal\" or \"external\", got %q", local.effective_ceph_mode)
  }
}

check "external_cluster_requirements" {
  assert {
    condition = local.effective_ceph_mode != "external" || (
      trimspace(try(local.external_ceph.fsid, "")) != "" &&
      length(local.external_monitors) > 0 &&
      trimspace(local.external_ceph_secret) != ""
    )
    error_message = "external mode requires ceph_external.fsid, monitors, and connection credentials in ceph_constants.tf."
  }
}

resource "null_resource" "external_rbd_pools" {
  for_each = local.external_block_pools

  triggers = {
    pool_spec      = jsonencode(each.value)
    converge_every = timestamp()
  }

  provisioner "local-exec" {
    command = format(
      "%s ensure-rbd-pool --name %s --type %s --pg-num %s --size %s --min-size %s%s%s",
      "${path.module}/pve-ceph-external.sh",
      each.value.name,
      each.value.type,
      tostring(each.value.pg_num),
      tostring(each.value.size),
      tostring(each.value.min_size),
      each.value.type == "ec" && local.external_ceph_ssh_host != "" ? format(" --ssh-host %s", local.external_ceph_ssh_host) : "",
      each.value.type == "ec" ? format(" --k %s --m %s", tostring(try(each.value.k, 0)), tostring(try(each.value.m, 0))) : ""
    )
  }
}

resource "null_resource" "external_ceph_filesystems" {
  for_each = local.external_filesystems

  triggers = {
    filesystem_spec = jsonencode(each.value)
    converge_every  = timestamp()
  }

  provisioner "local-exec" {
    command = format(
      "%s ensure-cephfs --name %s --type %s --metadata-pool %s --metadata-pg-num %s --metadata-size %s --metadata-min-size %s --data-pool %s --data-pg-num %s --data-size %s --data-min-size %s%s",
      "${path.module}/pve-ceph-external.sh",
      each.value.name,
      each.value.type,
      each.value.metadata_pool,
      tostring(each.value.metadata_pg_num),
      tostring(each.value.metadata_size),
      tostring(each.value.metadata_min_size),
      each.value.data_pool,
      tostring(each.value.data_pg_num),
      tostring(each.value.data_size),
      tostring(each.value.data_min_size),
      each.value.type == "ec" ? format(" --ec-data-pool %s --ec-data-pg-num %s --ec-data-size %s --ec-data-min-size %s --k %s --m %s", each.value.ec_data_pool, tostring(each.value.ec_data_pg_num), tostring(each.value.ec_data_size), tostring(each.value.ec_data_min_size), tostring(each.value.k), tostring(each.value.m)) : ""
    )

    environment = {
      CEPH_SSH_HOST = local.external_ceph_ssh_host
    }
  }
}

resource "kubernetes_secret_v1" "rook_ceph_mon" {
  count = local.effective_ceph_mode == "external" ? 1 : 0

  metadata {
    name      = "rook-ceph-mon"
    namespace = local.effective_ceph_namespace
  }

  data = {
    "ceph-username" = local.external_ceph_username
    "ceph-secret"   = local.external_ceph_secret
    "mon-secret"    = local.external_ceph_secret
    "admin-secret"  = local.external_ceph_secret
    "fsid"          = try(local.external_ceph.fsid, "")
  }
}

resource "kubernetes_config_map_v1" "rook_ceph_mon_endpoints" {
  count = local.effective_ceph_mode == "external" ? 1 : 0

  metadata {
    name      = "rook-ceph-mon-endpoints"
    namespace = local.effective_ceph_namespace
  }

  data = {
    "data"                    = local.external_mon_data
    "mapping"                 = local.external_mon_mapping
    "maxMonId"                = tostring(max(length(local.external_monitors) - 1, 0))
    "csi-cluster-config-json" = local.external_csi_cluster_config
  }
}

resource "kubernetes_manifest" "rook_cluster_internal" {
  count    = local.effective_ceph_mode == "internal" ? 1 : 0
  manifest = local.internal_cluster_manifest

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  depends_on = [
    null_resource.external_rbd_pools,
    null_resource.external_ceph_filesystems,
    kubernetes_secret_v1.rook_ceph_mon,
    kubernetes_config_map_v1.rook_ceph_mon_endpoints,
  ]
}

resource "kubernetes_manifest" "rook_cluster_external" {
  count    = local.effective_ceph_mode == "external" ? 1 : 0
  manifest = local.external_cluster_manifest

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  depends_on = [
    null_resource.external_rbd_pools,
    null_resource.external_ceph_filesystems,
    kubernetes_secret_v1.rook_ceph_mon,
    kubernetes_config_map_v1.rook_ceph_mon_endpoints,
  ]
}
