locals {
  portainer_hostname  = "portainer.${local.domain}"
  grafana_hostname    = "grafana.${local.domain}"
  prometheus_hostname = "prometheus.${local.domain}"
  portainer_tls_secret_name  = "portainer-tls"
  grafana_tls_secret_name    = "grafana-tls"
  prometheus_tls_secret_name = "prometheus-tls"

  storage_class = "${local.ceph_name_prefix}-rbd-ec"

  portainer_image_tag     = "2.33.6"
  portainer_storage_class = local.storage_class
  portainer_pvc_size      = "10Gi"

  grafana_storage_size    = "5Gi"
  prometheus_storage_size = "20Gi"
  loki_storage_size       = "20Gi"

  prometheus_retention = "15d"
  loki_retention       = "168h" # 7 days

  grafana_image_tag    = "12.4.0-20648027705-ubuntu"
  prometheus_image_tag = "v3.8.1"
  loki_image_tag       = "3.6.3"
  promtail_image_tag   = "3.6.3"
  kube_state_metrics_image_tag = "v2.17.0"

  grafana_admin_user            = "admin"
  grafana_admin_password_length = 24

  prometheus_cpu_request = "200m"
  prometheus_cpu_limit   = "1"
  prometheus_mem_request = "1Gi"
  prometheus_mem_limit   = "4Gi"

  grafana_cpu_request = "100m"
  grafana_cpu_limit   = "500m"
  grafana_mem_request = "256Mi"
  grafana_mem_limit   = "1Gi"

  loki_cpu_request = "200m"
  loki_cpu_limit   = "1"
  loki_mem_request = "512Mi"
  loki_mem_limit   = "2Gi"

  promtail_cpu_request = "100m"
  promtail_cpu_limit   = "300m"
  promtail_mem_request = "128Mi"
  promtail_mem_limit   = "256Mi"

  kube_state_metrics_cpu_request = "100m"
  kube_state_metrics_cpu_limit   = "300m"
  kube_state_metrics_mem_request = "128Mi"
  kube_state_metrics_mem_limit   = "256Mi"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = "portainer"
      secret_name = local.portainer_tls_secret_name
    },
    {
      certificate = local.default_certificate_name
      namespace   = "monitoring"
      secret_name = local.grafana_tls_secret_name
    },
    {
      certificate = local.default_certificate_name
      namespace   = "monitoring"
      secret_name = local.prometheus_tls_secret_name
    },
  ]
}
