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
  prometheus_storage_size = "100Gi"
  loki_storage_size       = "80Gi"

  prometheus_retention = "15d"
  # Prometheus starts deleting old TSDB blocks when it reaches 80% of the PVC size,
  # leaving head/WAL room so the volume is less likely to hit 100%.
  # Docs: https://prometheus.io/docs/prometheus/latest/storage/#right-sizing-retention-size
  prometheus_retention_size_percent = 80
  loki_retention       = "168h" # 7 days

  grafana_image_tag            = "13.0.2"
  prometheus_image_tag         = "v3.12.0"
  loki_image_tag               = "3.7.2"
  promtail_image_tag           = "3.6.10"
  kube_state_metrics_image_tag = "v2.18.0"
  node_exporter_image_tag      = "v1.11.1"

  grafana_admin_user                    = "admin"
  grafana_admin_password_length         = 24
  grafana_db_name                       = "grafana"
  grafana_db_username                   = "grafana"
  grafana_postgres_image_tag            = "18.4"
  grafana_postgres_exporter_image_tag   = "v0.19.1"
  grafana_postgres_pvc_size             = "8Gi"
  grafana_postgres_password_length      = 24
  grafana_postgres_cpu_request          = "100m"
  grafana_postgres_cpu_limit            = "500m"
  grafana_postgres_mem_request          = "256Mi"
  grafana_postgres_mem_limit            = "256Mi"
  grafana_wait_for_postgres_cpu_request = "20m"
  grafana_wait_for_postgres_cpu_limit   = "100m"
  grafana_wait_for_postgres_mem_request = "32Mi"
  grafana_wait_for_postgres_mem_limit   = "32Mi"
  grafana_auth_keycloak_realm           = "company"
  grafana_auth_view_groups              = ["monitoring-view"]
  grafana_auth_edit_groups              = ["monitoring-edit"]
  grafana_auth_name                     = "Keycloak"
  grafana_auth_scopes                   = "openid profile email"
  grafana_auth_auto_login               = false
  grafana_auth_allow_sign_up            = true
  grafana_auth_ca_secret_name           = "grafana-oauth-ca"

  grafana_dashboard_provisioning_enabled           = true
  grafana_dashboard_provisioning_pvc_create        = true
  grafana_dashboard_provisioning_pvc_name          = "dashboards-provisioning"
  grafana_dashboard_provisioning_pvc_storage_class = "${local.ceph_name_prefix}-cephfs-ec"
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
  prometheus_oauth2_proxy_mem_request       = "128Mi"
  prometheus_oauth2_proxy_mem_limit         = "128Mi"
  prometheus_api_basic_auth_secret_name     = "prometheus-api-basic-auth"
  prometheus_api_basic_auth_password_length = 32

  prometheus_cpu_request = "200m"
  prometheus_cpu_limit   = "1"
  prometheus_mem_request = "4Gi"
  prometheus_mem_limit   = "4Gi"
  prometheus_go_mem_limit_percent = 80
  prometheus_go_gc_percent        = 50

  # Compresses Prometheus TSDB WAL segments to reduce WAL bytes that must be read after restarts.
  # Docs: https://prometheus.io/docs/prometheus/latest/storage/#operational-aspects
  prometheus_wal_compression = true

  # Caps concurrent PromQL queries so dashboard/API load leaves CPU and memory for TSDB WAL replay and compaction work.
  # Docs: https://prometheus.io/docs/prometheus/latest/command-line/prometheus/#flags
  prometheus_query_max_concurrency = 10

  grafana_cpu_request          = "500m"
  grafana_cpu_limit            = "2"
  grafana_mem_request          = "1Gi"
  grafana_mem_limit            = "1Gi"
  grafana_go_mem_limit_percent = 90
  grafana_go_gc_percent        = 50

  loki_cpu_request = "200m"
  loki_cpu_limit   = "1"
  loki_mem_request = "1Gi"
  loki_mem_limit   = "1Gi"

  promtail_cpu_request = "100m"
  promtail_cpu_limit   = "300m"
  promtail_mem_request = "256Mi"
  promtail_mem_limit   = "256Mi"

  kube_state_metrics_cpu_request = "100m"
  kube_state_metrics_cpu_limit   = "300m"
  kube_state_metrics_mem_request = "256Mi"
  kube_state_metrics_mem_limit   = "256Mi"
  node_exporter_cpu_request      = "50m"
  node_exporter_cpu_limit        = "200m"
  node_exporter_mem_request      = "128Mi"
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
