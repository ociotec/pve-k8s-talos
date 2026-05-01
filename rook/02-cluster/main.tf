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

  external_ceph = try(local.ceph_external, {})
  external_monitors = try(local.external_ceph.monitors, [])
  external_mon_data = join(",", [for monitor in local.external_monitors : format("%s=%s", monitor.id, monitor.endpoint)])
  external_mon_mapping = jsonencode({
    node = {
      for monitor in local.external_monitors : monitor.id => {
        Name     = split(":", monitor.endpoint)[0]
        Hostname = split(":", monitor.endpoint)[0]
        Address  = split(":", monitor.endpoint)[0]
      }
    }
  })
  external_csi_cluster_config = jsonencode([
    {
      clusterID = local.effective_ceph_namespace
      monitors  = [for monitor in local.external_monitors : monitor.endpoint]
      namespace = ""
    }
  ])
  external_ceph_username = trimspace(try(local.external_ceph.admin_secret, "")) != "" ? try(local.external_ceph.admin_username, "client.admin") : try(local.external_ceph.healthcheck_username, "client.healthchecker")
  external_ceph_secret   = trimspace(try(local.external_ceph.admin_secret, "")) != "" ? try(local.external_ceph.admin_secret, "") : try(local.external_ceph.healthcheck_secret, "")

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
      (local.block_ec.pool_name) = {
        name     = local.block_ec.pool_name
        type     = "ec"
        pg_num   = local.block_ec.pg_num
        size     = local.block_ec.metadata_size
        min_size = local.block_ec.metadata_min_size
        k        = local.block_ec.k
        m        = local.block_ec.m
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
    pool_spec    = jsonencode(each.value)
  }

  provisioner "local-exec" {
    command = format(
      "%s ensure-rbd-pool --name %s --type %s --pg-num %s --size %s --min-size %s%s",
      "${path.module}/pve-ceph-external.sh",
      each.value.name,
      each.value.type,
      tostring(each.value.pg_num),
      tostring(each.value.size),
      tostring(each.value.min_size),
      each.value.type == "ec" ? format(" --k %s --m %s", tostring(try(each.value.k, 0)), tostring(try(each.value.m, 0))) : ""
    )
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
    "data"                  = local.external_mon_data
    "mapping"               = local.external_mon_mapping
    "maxMonId"              = tostring(max(length(local.external_monitors) - 1, 0))
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
    kubernetes_secret_v1.rook_ceph_mon,
    kubernetes_config_map_v1.rook_ceph_mon_endpoints,
  ]
}
