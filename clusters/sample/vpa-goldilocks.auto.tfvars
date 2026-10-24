# Monitoring functionality enabled by default; configure the cluster identity realm.
# Goldilocks uses goldilocks.<cluster-domain> and the default TLS certificate.
vpa_goldilocks = {
  oauth2_proxy_image_tag = "v7.15.5"
  recommender_image_tag = "1.8.1"
  vpa_enabled        = true
  goldilocks_enabled = true
  keycloak_realm     = "company"
  allowed_groups     = ["k8s-admins", "monitoring-view"]
  # Defaults to true: analyze current and future namespaces automatically.
  # Set false to analyze only namespaces labeled goldilocks.fairwinds.com/enabled=true.
  all_namespaces = true
  # VPA recommender and Goldilocks controller/dashboard CPU and RAM
  # are sized automatically from total planned worker vCPU and RAM, even on an
  # empty cluster. Omit their settings (or set null) to use automatic sizing.
  # Explicit settings override the calculated value; use only for exceptions.
  # Goldilocks Go soft limits default to 80% of their effective memory.
  # go_mem_limit_percent    = 80
  # recommender_cpu_request = null
  # recommender_cpu_limit   = null
  # recommender_memory      = null
  # controller_cpu_request  = null
  # controller_cpu_limit    = null
  # controller_memory       = null
  # dashboard_cpu_request   = null
  # dashboard_cpu_limit     = null
  # dashboard_memory        = null
}
