terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
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
  ceph_hostname = try(local.ceph_hostname, "ceph.${local.domain}")
  ceph_tls_secret_name = "rook-ceph-dashboard-tls"
  ceph_dashboard_resources = concat(
    [
      for doc in split("\n---\n", file("${path.module}/../manifests/dashboard-external-https.yaml")) :
      yamldecode(doc)
      if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
    ],
    [
      for doc in split("\n---\n", templatefile("${path.module}/rook-ceph-dashboard-ingress.yaml", {
        ceph_hostname        = local.ceph_hostname
        ceph_tls_secret_name = local.ceph_tls_secret_name
      })) :
      yamldecode(doc)
      if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
    ]
  )
  rook_dashboard_certificates = [
    for m in local.ceph_dashboard_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  rook_dashboard_ingress = [
    for m in local.ceph_dashboard_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  rook_dashboard_other = [
    for m in local.ceph_dashboard_resources : m
    if !contains(["Certificate", "Ingress"], try(m.kind, ""))
  ]
  preissued_ceph_certificate = try(local.available_certificates[local.default_certificate_name], null)
  preissued_ceph_cert_content = local.preissued_ceph_certificate != null ? try(file(local.preissued_ceph_certificate.cert_path), "") : ""
  preissued_ceph_key_content  = local.preissued_ceph_certificate != null ? try(file(local.preissued_ceph_certificate.key_path), "") : ""
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

check "preissued_ceph_certificate" {
  assert {
    condition = local.tls_source != "preissued" || (
      local.preissued_ceph_certificate != null &&
      trimspace(local.preissued_ceph_cert_content) != "" &&
      trimspace(local.preissued_ceph_key_content) != ""
    )
    error_message = "default_certificate_name must reference a readable certificate/key pair in available_certificates for the Rook dashboard."
  }
}

resource "kubernetes_manifest" "rook_dashboard_other" {
  for_each = { for i, m in local.rook_dashboard_other : i => m }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${var.kubeconfig_path} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_manifest" "rook_dashboard_certificates" {
  for_each = { for i, m in local.rook_dashboard_certificates : i => m }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.rook_dashboard_other,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "kubernetes_secret_v1" "preissued_ceph_tls" {
  count = local.tls_source == "preissued" ? 1 : 0

  metadata {
    name      = local.ceph_tls_secret_name
    namespace = "rook-ceph"
  }

  data = {
    "tls.crt" = local.preissued_ceph_cert_content
    "tls.key" = local.preissued_ceph_key_content
  }

  type = "kubernetes.io/tls"
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${var.kubeconfig_path} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${var.kubeconfig_path} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "rook_dashboard_ingress" {
  for_each = { for i, m in local.rook_dashboard_ingress : i => m }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.rook_dashboard_other,
    kubernetes_manifest.rook_dashboard_certificates,
    kubernetes_secret_v1.preissued_ceph_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "rook_ceph_dashboard_url" {
  value = "https://${local.ceph_hostname}"
}
