terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/../../kubeconfig")
}

locals {
  constants_source = file("${path.module}/ceph_constants.tf")
  csi_addons_enabled = can(regex("(?m)^\\s*ceph_csi_addons_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*ceph_csi_addons_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : false
  infrastructure_labels = {
    "app.kubernetes.io/part-of"    = "rook-ceph"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "rook"
  }
  csi_addons_crds = [
    for doc in split("\n---\n", file("${path.module}/../manifests/csi-addons/crds.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  csi_addons_rbac_raw = [
    for doc in split("\n---\n", file("${path.module}/../manifests/csi-addons/rbac.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  csi_addons_rbac = [
    for manifest in local.csi_addons_rbac_raw : merge(manifest, {
      metadata = merge(manifest.metadata, {
        labels = merge(try(manifest.metadata.labels, {}), local.infrastructure_labels)
      })
    })
  ]
  csi_addons_controller_raw = [
    for doc in split("\n---\n", file("${path.module}/../manifests/csi-addons/setup-controller.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  csi_addons_controller = [
    for manifest in local.csi_addons_controller_raw : merge(
      manifest,
      {
        metadata = merge(manifest.metadata, {
          labels = merge(try(manifest.metadata.labels, {}), local.infrastructure_labels)
        })
      },
      try(manifest.kind, "") == "Deployment" ? {
        spec = merge(manifest.spec, {
          replicas = 2
          template = merge(manifest.spec.template, {
            metadata = merge(manifest.spec.template.metadata, {
              labels = merge(try(manifest.spec.template.metadata.labels, {}), local.infrastructure_labels, {
                "app.kubernetes.io/instance"  = "csi-addons"
                "app.kubernetes.io/component" = "controller"
              })
            })
            spec = merge(manifest.spec.template.spec, {
              priorityClassName = "infra-high"
              containers = [
                for container in manifest.spec.template.spec.containers : merge(container, {
                  resources = {
                    requests = {
                      cpu    = "50m"
                      memory = "256Mi"
                    }
                    limits = {
                      cpu    = "500m"
                      memory = "256Mi"
                    }
                  }
                  readinessProbe = merge(container.readinessProbe, {
                    timeoutSeconds   = 1
                    successThreshold = 1
                    httpGet = merge(container.readinessProbe.httpGet, {
                      scheme = "HTTP"
                    })
                  })
                  livenessProbe = merge(container.livenessProbe, {
                    timeoutSeconds   = 1
                    successThreshold = 1
                    httpGet = merge(container.livenessProbe.httpGet, {
                      scheme = "HTTP"
                    })
                  })
                })
              ]
            })
          })
        })
      } : {}
    )
  ]
  csi_addons_controller_namespace = [
    for manifest in local.csi_addons_controller : manifest
    if try(manifest.kind, "") == "Namespace"
  ]
  csi_addons_controller_other = [
    for manifest in local.csi_addons_controller : manifest
    if try(manifest.kind, "") != "Namespace"
  ]
  rook_crds = concat(
    [
      for doc in split("\n---\n", file("${path.module}/../manifests/crds.yaml")) :
      yamldecode(doc)
      if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
    ],
    [
      for doc in split("\n---\n", file("${path.module}/../manifests/crds-nvmeof.yaml")) :
      yamldecode(doc)
      if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
    ],
  )
  rook_common = [
    for doc in split("\n---\n", file("${path.module}/../manifests/common.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  rook_operator = [
    for doc in split("\n---\n", templatefile("${path.module}/../manifests/operator.yaml", {
      csi_addons_enabled = tostring(local.csi_addons_enabled)
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  rook_toolbox = [
    for doc in split("\n---\n", file("${path.module}/../manifests/toolbox.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]

  rook_common_namespace = [
    for m in local.rook_common : m
    if try(m.kind, "") == "Namespace"
  ]
  rook_common_other = [
    for m in local.rook_common : m
    if try(m.kind, "") != "Namespace"
  ]
}

resource "kubernetes_manifest" "rook_crds" {
  for_each = { for i, m in local.rook_crds : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "csi_addons_crds" {
  for_each = { for i, manifest in local.csi_addons_crds : tostring(i) => manifest if local.csi_addons_enabled }
  manifest = each.value
}

resource "kubernetes_manifest" "csi_addons_namespace" {
  for_each = { for i, manifest in local.csi_addons_controller_namespace : tostring(i) => manifest if local.csi_addons_enabled }
  manifest = each.value

  depends_on = [kubernetes_manifest.csi_addons_crds]
}

resource "kubernetes_manifest" "csi_addons_rbac" {
  for_each = { for i, manifest in local.csi_addons_rbac : tostring(i) => manifest if local.csi_addons_enabled }
  manifest = each.value

  depends_on = [kubernetes_manifest.csi_addons_namespace]
}

resource "kubernetes_manifest" "csi_addons_controller" {
  for_each = { for i, manifest in local.csi_addons_controller_other : tostring(i) => manifest if local.csi_addons_enabled }
  manifest = each.value

  computed_fields = try(each.value.kind, "") == "Deployment" ? [
    "metadata.annotations",
    "spec.template.metadata.annotations",
  ] : []

  depends_on = [kubernetes_manifest.csi_addons_rbac]
}

resource "kubernetes_manifest" "rook_common_namespace" {
  for_each = { for i, m in local.rook_common_namespace : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.rook_crds,
  ]
}

resource "kubernetes_manifest" "rook_common" {
  for_each   = { for i, m in local.rook_common_other : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.rook_common_namespace]
}

resource "kubernetes_manifest" "rook_operator" {
  for_each = { for i, m in local.rook_operator : i => m }
  manifest = each.value
  computed_fields = try(each.value.kind, "") == "Deployment" ? [
    "spec.template.metadata.annotations[\"kubectl.kubernetes.io/restartedAt\"]",
    "object.spec.template.metadata.annotations",
    "object.spec.template.metadata.annotations[\"kubectl.kubernetes.io/restartedAt\"]",
  ] : []
  lifecycle {
    ignore_changes = [
      object.spec.template.metadata.annotations,
      object.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
  depends_on = [kubernetes_manifest.rook_common]
}

resource "kubernetes_manifest" "rook_toolbox" {
  for_each   = { for i, m in local.rook_toolbox : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.rook_operator]
}
