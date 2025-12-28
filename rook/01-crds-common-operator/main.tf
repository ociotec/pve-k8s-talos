terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1"
    }
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/../../kubeconfig")
}

locals {
  rook_crds = [
    for doc in split("\n---\n", file("${path.module}/../manifests/crds.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  rook_common = [
    for doc in split("\n---\n", file("${path.module}/../manifests/common.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  rook_operator = [
    for doc in split("\n---\n", file("${path.module}/../manifests/operator.yaml")) :
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
  for_each   = { for i, m in local.rook_operator : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.rook_common]
}
