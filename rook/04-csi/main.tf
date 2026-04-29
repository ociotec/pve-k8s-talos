terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1"
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
  effective_ceph_mode      = try(local.ceph_mode, "internal")
  effective_ceph_namespace = try(local.ceph_namespace, "rook-ceph")
  effective_ceph_name_prefix = try(local.ceph_name_prefix, "cluster")

  effective_ceph_block_replicated = merge(
    {
      enabled            = false
      pool_name          = "${local.effective_ceph_name_prefix}-rbd-replica"
      storage_class_name = "${local.effective_ceph_name_prefix}-rbd-replica"
      size               = 3
      min_size           = 2
      failure_domain     = "host"
    },
    try(local.ceph_block_replicated, {})
  )

  effective_ceph_block_ec = merge(
    {
      enabled            = false
      pool_name          = "${local.effective_ceph_name_prefix}-rbd-ec"
      data_pool_name     = "${local.effective_ceph_name_prefix}-rbd-ec-data"
      metadata_pool_name = "${local.effective_ceph_name_prefix}-rbd-ec-metadata"
      storage_class_name = "${local.effective_ceph_name_prefix}-rbd-ec"
      metadata_size      = 3
      metadata_min_size  = 2
      failure_domain     = "host"
      k                  = 2
      m                  = 1
    },
    try(local.ceph_block_ec, {})
  )

  effective_ceph_filesystem_replicated = merge(
    {
      enabled                        = false
      filesystem_name                = "${local.effective_ceph_name_prefix}-cephfs-replica"
      metadata_pool_name             = "${local.effective_ceph_name_prefix}-cephfs-replica-metadata"
      data_pool_name                 = "${local.effective_ceph_name_prefix}-cephfs-replica-data"
      storage_class_name             = "${local.effective_ceph_name_prefix}-cephfs-replica"
      size                           = 3
      min_size                       = 2
      failure_domain                 = "host"
      metadata_server_active_count   = 1
      metadata_server_active_standby = true
      preserve_filesystem_on_delete  = true
    },
    try(local.ceph_filesystem_replicated, {})
  )

  effective_ceph_filesystem_ec = merge(
    {
      enabled                        = false
      filesystem_name                = "${local.effective_ceph_name_prefix}-cephfs-ec"
      metadata_pool_name             = "${local.effective_ceph_name_prefix}-cephfs-ec-metadata"
      default_data_pool_name         = "${local.effective_ceph_name_prefix}-cephfs-ec-default"
      ec_data_pool_name              = "${local.effective_ceph_name_prefix}-cephfs-ec-data"
      storage_class_name             = "${local.effective_ceph_name_prefix}-cephfs-ec"
      metadata_size                  = 3
      metadata_min_size              = 2
      default_data_size              = 3
      default_data_min_size          = 2
      failure_domain                 = "host"
      k                              = 2
      m                              = 1
      metadata_server_active_count   = 1
      metadata_server_active_standby = true
      preserve_filesystem_on_delete  = true
    },
    try(local.ceph_filesystem_ec, {})
  )

  enable_block_replicated      = local.effective_ceph_block_replicated.enabled
  enable_block_ec              = local.effective_ceph_block_ec.enabled
  enable_filesystem_replicated = local.effective_ceph_filesystem_replicated.enabled
  enable_filesystem_ec         = local.effective_ceph_filesystem_ec.enabled

  create_block_pool_crs = local.effective_ceph_mode == "internal"
  create_filesystem_crs = local.effective_ceph_mode == "internal" || trimspace(try(local.ceph_external.admin_secret, "")) != ""

  block_pool_resources = concat(
    local.create_block_pool_crs && local.enable_block_replicated ? [
      {
        apiVersion = "ceph.rook.io/v1"
        kind       = "CephBlockPool"
        metadata = {
          name      = local.effective_ceph_block_replicated.pool_name
          namespace = local.effective_ceph_namespace
        }
        spec = {
          failureDomain = try(local.effective_ceph_block_replicated.failure_domain, "host")
          replicated = {
            size                   = local.effective_ceph_block_replicated.size
            requireSafeReplicaSize = true
          }
        }
      }
    ] : [],
    local.create_block_pool_crs && local.enable_block_ec ? [
      {
        apiVersion = "ceph.rook.io/v1"
        kind       = "CephBlockPool"
        metadata = {
          name      = local.effective_ceph_block_ec.metadata_pool_name
          namespace = local.effective_ceph_namespace
        }
        spec = {
          failureDomain = try(local.effective_ceph_block_ec.failure_domain, "host")
          replicated = {
            size                   = local.effective_ceph_block_ec.metadata_size
            requireSafeReplicaSize = true
          }
        }
      }
    ] : [],
    local.create_block_pool_crs && local.enable_block_ec ? [
      {
        apiVersion = "ceph.rook.io/v1"
        kind       = "CephBlockPool"
        metadata = {
          name      = local.effective_ceph_block_ec.data_pool_name
          namespace = local.effective_ceph_namespace
        }
        spec = {
          failureDomain = try(local.effective_ceph_block_ec.failure_domain, "host")
          erasureCoded = {
            dataChunks   = local.effective_ceph_block_ec.k
            codingChunks = local.effective_ceph_block_ec.m
          }
        }
      }
    ] : []
  )

  filesystem_resources = concat(
    local.create_filesystem_crs && local.enable_filesystem_replicated ? [
      {
        apiVersion = "ceph.rook.io/v1"
        kind       = "CephFilesystem"
        metadata = {
          name      = local.effective_ceph_filesystem_replicated.filesystem_name
          namespace = local.effective_ceph_namespace
        }
        spec = {
          preservePoolNames          = true
          preserveFilesystemOnDelete = try(local.effective_ceph_filesystem_replicated.preserve_filesystem_on_delete, true)
          metadataPool = {
            name          = local.effective_ceph_filesystem_replicated.metadata_pool_name
            failureDomain = try(local.effective_ceph_filesystem_replicated.failure_domain, "host")
            replicated = {
              size                   = local.effective_ceph_filesystem_replicated.size
              requireSafeReplicaSize = true
            }
          }
          dataPools = [
            {
              name          = local.effective_ceph_filesystem_replicated.data_pool_name
              failureDomain = try(local.effective_ceph_filesystem_replicated.failure_domain, "host")
              replicated = {
                size                   = local.effective_ceph_filesystem_replicated.size
                requireSafeReplicaSize = true
              }
            }
          ]
          metadataServer = {
            activeCount   = try(local.effective_ceph_filesystem_replicated.metadata_server_active_count, 1)
            activeStandby = try(local.effective_ceph_filesystem_replicated.metadata_server_active_standby, true)
          }
        }
      }
    ] : [],
    local.create_filesystem_crs && local.enable_filesystem_ec ? [
      {
        apiVersion = "ceph.rook.io/v1"
        kind       = "CephFilesystem"
        metadata = {
          name      = local.effective_ceph_filesystem_ec.filesystem_name
          namespace = local.effective_ceph_namespace
        }
        spec = {
          preservePoolNames          = true
          preserveFilesystemOnDelete = try(local.effective_ceph_filesystem_ec.preserve_filesystem_on_delete, true)
          metadataPool = {
            name          = local.effective_ceph_filesystem_ec.metadata_pool_name
            failureDomain = try(local.effective_ceph_filesystem_ec.failure_domain, "host")
            replicated = {
              size                   = local.effective_ceph_filesystem_ec.metadata_size
              requireSafeReplicaSize = true
            }
          }
          dataPools = [
            {
              name          = local.effective_ceph_filesystem_ec.default_data_pool_name
              failureDomain = try(local.effective_ceph_filesystem_ec.failure_domain, "host")
              replicated = {
                size                   = local.effective_ceph_filesystem_ec.default_data_size
                requireSafeReplicaSize = true
              }
            },
            {
              name          = local.effective_ceph_filesystem_ec.ec_data_pool_name
              failureDomain = try(local.effective_ceph_filesystem_ec.failure_domain, "host")
              erasureCoded = {
                dataChunks   = local.effective_ceph_filesystem_ec.k
                codingChunks = local.effective_ceph_filesystem_ec.m
              }
              parameters = {
                allow_ec_overwrites = "true"
              }
            }
          ]
          metadataServer = {
            activeCount   = try(local.effective_ceph_filesystem_ec.metadata_server_active_count, 1)
            activeStandby = try(local.effective_ceph_filesystem_ec.metadata_server_active_standby, true)
          }
        }
      }
    ] : []
  )

  storageclass_resources = concat(
    local.enable_block_replicated ? [
      {
        apiVersion = "storage.k8s.io/v1"
        kind       = "StorageClass"
        metadata = {
          name = local.effective_ceph_block_replicated.storage_class_name
        }
        provisioner = "rook-ceph.rbd.csi.ceph.com"
        parameters = {
          clusterID                                               = local.effective_ceph_namespace
          pool                                                    = local.effective_ceph_block_replicated.pool_name
          imageFormat                                             = "2"
          imageFeatures                                           = "layering"
          "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/provisioner-secret-namespace"       = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/controller-expand-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-publish-secret-name"     = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/controller-publish-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-rbd-node"
          "csi.storage.k8s.io/node-stage-secret-namespace"        = local.effective_ceph_namespace
          "csi.storage.k8s.io/fstype"                             = "ext4"
        }
        allowVolumeExpansion = true
        reclaimPolicy        = "Delete"
      }
    ] : [],
    local.enable_block_ec ? [
      {
        apiVersion = "storage.k8s.io/v1"
        kind       = "StorageClass"
        metadata = {
          name = local.effective_ceph_block_ec.storage_class_name
        }
        provisioner = "rook-ceph.rbd.csi.ceph.com"
        parameters = {
          clusterID                                               = local.effective_ceph_namespace
          pool                                                    = local.effective_ceph_block_ec.metadata_pool_name
          dataPool                                                = local.effective_ceph_block_ec.data_pool_name
          imageFormat                                             = "2"
          imageFeatures                                           = "layering"
          "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/provisioner-secret-namespace"       = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/controller-expand-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-publish-secret-name"     = "rook-csi-rbd-provisioner"
          "csi.storage.k8s.io/controller-publish-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-rbd-node"
          "csi.storage.k8s.io/node-stage-secret-namespace"        = local.effective_ceph_namespace
          "csi.storage.k8s.io/fstype"                             = "ext4"
        }
        allowVolumeExpansion = true
        reclaimPolicy        = "Delete"
      }
    ] : [],
    local.enable_filesystem_replicated ? [
      {
        apiVersion = "storage.k8s.io/v1"
        kind       = "StorageClass"
        metadata = {
          name = local.effective_ceph_filesystem_replicated.storage_class_name
        }
        provisioner = "rook-ceph.cephfs.csi.ceph.com"
        parameters = {
          clusterID                                               = local.effective_ceph_namespace
          fsName                                                  = local.effective_ceph_filesystem_replicated.filesystem_name
          pool                                                    = local.effective_ceph_filesystem_replicated.data_pool_name
          "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/provisioner-secret-namespace"       = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/controller-expand-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-publish-secret-name"     = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/controller-publish-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-cephfs-node"
          "csi.storage.k8s.io/node-stage-secret-namespace"        = local.effective_ceph_namespace
        }
        allowVolumeExpansion = true
        reclaimPolicy        = "Delete"
      }
    ] : [],
    local.enable_filesystem_ec ? [
      {
        apiVersion = "storage.k8s.io/v1"
        kind       = "StorageClass"
        metadata = {
          name = local.effective_ceph_filesystem_ec.storage_class_name
        }
        provisioner = "rook-ceph.cephfs.csi.ceph.com"
        parameters = {
          clusterID                                               = local.effective_ceph_namespace
          fsName                                                  = local.effective_ceph_filesystem_ec.filesystem_name
          pool                                                    = local.effective_ceph_filesystem_ec.ec_data_pool_name
          "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/provisioner-secret-namespace"       = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/controller-expand-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/controller-publish-secret-name"     = "rook-csi-cephfs-provisioner"
          "csi.storage.k8s.io/controller-publish-secret-namespace" = local.effective_ceph_namespace
          "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-cephfs-node"
          "csi.storage.k8s.io/node-stage-secret-namespace"        = local.effective_ceph_namespace
        }
        allowVolumeExpansion = true
        reclaimPolicy        = "Delete"
      }
    ] : []
  )
}

check "ceph_mode_valid" {
  assert {
    condition     = contains(["internal", "external"], local.effective_ceph_mode)
    error_message = format("ceph_mode must be \"internal\" or \"external\", got %q", local.effective_ceph_mode)
  }
}

check "external_filesystem_admin_required" {
  assert {
    condition     = local.effective_ceph_mode != "external" || !(local.enable_filesystem_replicated || local.enable_filesystem_ec) || trimspace(try(local.ceph_external.admin_secret, "")) != ""
    error_message = "External CephFS resources require ceph_external.admin_secret in ceph_constants.tf so Rook can manage filesystem CRs on the external cluster."
  }
}

resource "kubernetes_manifest" "ceph_pools_and_filesystems" {
  for_each = {
    for i, manifest in concat(local.block_pool_resources, local.filesystem_resources) : i => manifest
  }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }
}

resource "kubernetes_manifest" "rook_storageclass" {
  for_each = { for i, manifest in local.storageclass_resources : i => manifest }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.ceph_pools_and_filesystems,
  ]
}
