locals {
  grafana_hostname               = "grafana.${local.domain}"
  prometheus_hostname            = "prometheus.${local.domain}"
  prometheus_api_hostname        = "prometheus-api.${local.domain}"
  grafana_tls_secret_name        = "grafana-tls"
  prometheus_tls_secret_name     = "prometheus-tls"
  prometheus_api_tls_secret_name = local.prometheus_tls_secret_name

  ec_storage_class      = "${local.ceph_name_prefix}-rbd-ec"
  replica_storage_class = "${local.ceph_name_prefix}-rbd-replica"

  grafana_storage_class          = local.ec_storage_class
  grafana_postgres_storage_class = local.ec_storage_class
  loki_storage_class             = local.ec_storage_class
  prometheus_storage_class       = local.replica_storage_class

  grafana_storage_size    = "5Gi"
  prometheus_storage_size = "20Gi"
  loki_storage_size       = "20Gi"

  prometheus_retention = "15d"
  loki_retention       = "168h" # 7 days

  grafana_image_tag            = "13.0.1"
  prometheus_image_tag         = "v3.11.3"
  loki_image_tag               = "3.7.1"
  promtail_image_tag           = "3.6.10"
  kube_state_metrics_image_tag = "v2.18.0"
  node_exporter_image_tag      = "v1.11.1"

  grafana_admin_user                  = "admin"
  grafana_admin_password_length       = 24
  grafana_db_name                     = "grafana"
  grafana_db_username                 = "grafana"
  grafana_postgres_image_tag          = "18.3"
  grafana_postgres_exporter_image_tag = "v0.19.1"
  grafana_postgres_pvc_size           = "8Gi"
  grafana_postgres_password_length    = 24
  grafana_auth_keycloak_realm         = "company"
  grafana_auth_view_groups            = ["monitoring-view"]
  grafana_auth_edit_groups            = ["monitoring-edit"]
  grafana_auth_name                   = "Keycloak"
  grafana_auth_scopes                 = "openid profile email"
  grafana_auth_auto_login             = false
  grafana_auth_allow_sign_up          = true
  grafana_auth_ca_secret_name         = "grafana-oauth-ca"

  grafana_dashboard_provisioning_enabled           = false
  grafana_dashboard_provisioning_pvc_create        = false
  grafana_dashboard_provisioning_pvc_name          = "dashboards-provisioning"
  grafana_dashboard_provisioning_pvc_storage_class = local.grafana_storage_class
  grafana_dashboard_provisioning_pvc_access_modes  = ["ReadWriteMany"]
  grafana_dashboard_provisioning_pvc_size          = "1Gi"

  grafana_dashboard_provisioning_pvc_update_interval_seconds      = 30
  grafana_dashboard_provisioning_pvc_allow_ui_updates             = false
  grafana_dashboard_provisioning_pvc_disable_deletion             = false
  grafana_dashboard_provisioning_pvc_folders_from_files_structure = true

  prometheus_auth_keycloak_realm            = "company"
  prometheus_auth_allowed_groups            = ["monitoring-view", "monitoring-edit"]
  prometheus_auth_ca_secret_name            = "prometheus-oauth-ca"
  prometheus_oauth2_proxy_image_tag         = "v7.15.2"
  prometheus_oauth2_proxy_cookie_name       = "_prometheus_oauth2_proxy"
  prometheus_oauth2_proxy_cpu_request       = "50m"
  prometheus_oauth2_proxy_cpu_limit         = "200m"
  prometheus_oauth2_proxy_mem_request       = "64Mi"
  prometheus_oauth2_proxy_mem_limit         = "256Mi"
  prometheus_api_basic_auth_secret_name     = "prometheus-api-basic-auth"
  prometheus_api_basic_auth_password_length = 32

  prometheus_cpu_request = "1"
  prometheus_cpu_limit   = "2"
  prometheus_mem_request = "4Gi"
  prometheus_mem_limit   = "4Gi"

  # Compresses Prometheus TSDB WAL segments to reduce WAL bytes that must be read after restarts.
  # Docs: https://prometheus.io/docs/prometheus/latest/storage/#operational-aspects
  prometheus_wal_compression = true

  # Caps concurrent PromQL queries so dashboard/API load leaves CPU and memory for TSDB WAL replay and compaction work.
  # Docs: https://prometheus.io/docs/prometheus/latest/command-line/prometheus/#flags
  prometheus_query_max_concurrency = 10

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
  node_exporter_cpu_request      = "50m"
  node_exporter_cpu_limit        = "200m"
  node_exporter_mem_request      = "64Mi"
  node_exporter_mem_limit        = "128Mi"

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
