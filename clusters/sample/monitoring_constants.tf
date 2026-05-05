locals {
  grafana_hostname           = "grafana.${local.domain}"
  prometheus_hostname        = "prometheus.${local.domain}"
  grafana_tls_secret_name    = "grafana-tls"
  prometheus_tls_secret_name = "prometheus-tls"

  storage_class = "${local.ceph_name_prefix}-rbd-ec"

  grafana_storage_size    = "5Gi"
  prometheus_storage_size = "20Gi"
  loki_storage_size       = "20Gi"

  prometheus_retention = "15d"
  loki_retention       = "168h" # 7 days

  grafana_image_tag            = "13.0.1"
  prometheus_image_tag         = "v3.11.2"
  loki_image_tag               = "3.7.1"
  promtail_image_tag           = "3.7.1"
  kube_state_metrics_image_tag = "v2.18.0"

  grafana_admin_user            = "admin"
  grafana_admin_password_length = 24
  grafana_auth_keycloak_realm   = ""
  grafana_auth_view_groups      = []
  grafana_auth_edit_groups      = []
  grafana_auth_name             = "Keycloak"
  grafana_auth_scopes           = "openid profile email"
  grafana_auth_auto_login       = false
  grafana_auth_allow_sign_up    = true
  grafana_auth_ca_secret_name   = "grafana-oauth-ca"

  prometheus_auth_keycloak_realm      = ""
  prometheus_auth_allowed_groups      = []
  prometheus_auth_ca_secret_name      = "prometheus-oauth-ca"
  prometheus_oauth2_proxy_image_tag   = "v7.12.0"
  prometheus_oauth2_proxy_cookie_name = "_prometheus_oauth2_proxy"
  prometheus_oauth2_proxy_cpu_request = "50m"
  prometheus_oauth2_proxy_cpu_limit   = "200m"
  prometheus_oauth2_proxy_mem_request = "64Mi"
  prometheus_oauth2_proxy_mem_limit   = "256Mi"

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
