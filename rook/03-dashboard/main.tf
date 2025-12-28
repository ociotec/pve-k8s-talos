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
  rook_dashboard = [
    for doc in split("\n---\n", file("${path.module}/../manifests/dashboard-external-https.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
}

resource "kubernetes_manifest" "rook_dashboard" {
  for_each = { for i, m in local.rook_dashboard : i => m }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }
}
