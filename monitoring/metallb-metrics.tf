locals {
  metallb_version_value       = try(regex("(?m)^\\s*metallb_version\\s*=\\s*\"([^\"]+)\"", file("${path.module}/k8s_net_constants.tf"))[0], "0.15.3")
  metallb_secure_metrics      = try(tonumber(split(".", local.metallb_version_value)[0]) > 0 || tonumber(split(".", local.metallb_version_value)[1]) >= 16, false)
  metallb_metrics_server_name = format("metallb-metrics.%s", local.domain)
  metallb_metrics_ca_content  = local.metallb_secure_metrics ? file(local.root_ca_crt) : ""
  metallb_metrics_config_hash = local.metallb_secure_metrics ? sha256(jsonencode([
    filesha256("${path.module}/prometheus.yaml"), local.metallb_metrics_server_name, local.metallb_metrics_ca_content
  ])) : ""
}

resource "kubernetes_config_map_v1" "metallb_metrics_ca" {
  count = local.metallb_secure_metrics ? 1 : 0
  metadata {
    name      = "prometheus-metallb-ca"
    namespace = "monitoring"
    labels = {
      "app.kubernetes.io/name"       = "prometheus"
      "app.kubernetes.io/instance"   = "prometheus"
      "app.kubernetes.io/component"  = "server"
      "app.kubernetes.io/part-of"    = "prometheus"
      "app.kubernetes.io/managed-by" = "infrastructure"
      "pve-k8s-talos/section"        = "monitoring"
    }
  }
  data       = { "ca.crt" = local.metallb_metrics_ca_content }
  depends_on = [kubernetes_manifest.monitoring_namespace]
}
