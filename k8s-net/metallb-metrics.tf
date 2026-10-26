locals {
  metallb_version_value       = try(regex("(?m)^\\s*metallb_version\\s*=\\s*\"([^\"]+)\"", local.constants_source)[0], "0.15.3")
  metallb_secure_metrics      = try(tonumber(split(".", local.metallb_version_value)[0]) > 0 || tonumber(split(".", local.metallb_version_value)[1]) >= 16, false)
  metallb_metrics_server_name = format("metallb-metrics.%s", local.domain)
  metallb_metrics_certificate = local.metallb_secure_metrics && local.tls_source == "preissued" ? file(local.available_certificates[local.default_certificate_name].cert_path) : (
    local.metallb_secure_metrics ? tls_locally_signed_cert.metallb_metrics[0].cert_pem : ""
  )
  metallb_metrics_private_key = local.metallb_secure_metrics && local.tls_source == "preissued" ? file(local.available_certificates[local.default_certificate_name].key_path) : (
    local.metallb_secure_metrics ? tls_private_key.metallb_metrics[0].private_key_pem : ""
  )
}

resource "tls_private_key" "metallb_metrics" {
  count       = local.metallb_secure_metrics && local.tls_source == "ca_issuer" ? 1 : 0
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "metallb_metrics" {
  count           = local.metallb_secure_metrics && local.tls_source == "ca_issuer" ? 1 : 0
  private_key_pem = tls_private_key.metallb_metrics[0].private_key_pem
  dns_names       = [local.metallb_metrics_server_name]
  subject {
    common_name = local.metallb_metrics_server_name
  }
}

resource "tls_locally_signed_cert" "metallb_metrics" {
  count                 = local.metallb_secure_metrics && local.tls_source == "ca_issuer" ? 1 : 0
  cert_request_pem      = tls_cert_request.metallb_metrics[0].cert_request_pem
  ca_cert_pem           = local.root_ca_cert_pem
  ca_private_key_pem    = local.root_ca_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "kubernetes_secret_v1" "metallb_metrics_tls" {
  count = local.metallb_secure_metrics ? 1 : 0
  metadata {
    name      = "metallb-metrics-tls"
    namespace = "metallb-system"
    labels = {
      "app.kubernetes.io/name"       = "metallb"
      "app.kubernetes.io/instance"   = "metallb"
      "app.kubernetes.io/part-of"    = "metallb"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/managed-by" = "infrastructure"
      "pve-k8s-talos/section"        = "k8s-net"
    }
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = local.metallb_metrics_certificate
    "tls.key" = local.metallb_metrics_private_key
  }
  depends_on = [kubernetes_manifest.metallb_native_namespace]
}
