# Monitoring functionality enabled by default; configure the cluster identity realm.
# Goldilocks uses goldilocks.<cluster-domain> and the default TLS certificate.
vpa_goldilocks = {
  vpa_enabled        = true
  goldilocks_enabled = true
  keycloak_realm     = "company"
  allowed_groups     = ["k8s-admins", "monitoring-view"]
  # Defaults to true: analyze current and future namespaces automatically.
  # Set false to analyze only namespaces labeled goldilocks.fairwinds.com/enabled=true.
  all_namespaces = true
  # Shared sizing defaults. Override only after reviewing measured usage.
  # recommender_cpu_request = "100m"
  # recommender_cpu_limit   = "500m"
  # recommender_memory      = "512Mi"
  # controller_cpu_request  = "50m"
  # controller_cpu_limit    = "200m"
  # controller_memory       = "256Mi"
  # dashboard_cpu_request   = "50m"
  # dashboard_cpu_limit     = "200m"
  # dashboard_memory        = "256Mi"
}
