locals {
  redpanda_namespace               = "kafka"
  redpanda_resource_name           = "redpanda"
  redpanda_cluster_id              = "GCS"
  redpanda_broker_k8s_annotation   = "kafka-node"
  redpanda_broker_data_host_path   = "/var/lib/kafka"
  redpanda_storage_class_name      = "redpanda-local"
  redpanda_console_hostname        = "redpanda-console.${local.domain}"
  redpanda_console_tls_secret_name = "redpanda-console-tls"
  redpanda_image                   = "docker.redpanda.com/redpandadata/redpanda:v26.1.6"
  redpanda_console_image           = "docker.redpanda.com/redpandadata/console:v3.7.2"

  redpanda_console_auth_keycloak_realm = "company"
  redpanda_console_auth_allowed_groups = ["k8s-admins"]
  redpanda_console_auth_ca_secret_name = "redpanda-console-oauth-ca"

  redpanda_console_oauth2_proxy_image_tag         = "v7.15.2"
  redpanda_console_oauth2_proxy_cookie_name       = "_redpanda_console_oauth2_proxy"
  redpanda_console_oauth2_proxy_cpu_request       = "50m"
  redpanda_console_oauth2_proxy_cpu_limit         = "200m"
  redpanda_console_oauth2_proxy_mem_request       = "128Mi"
  redpanda_console_oauth2_proxy_mem_limit         = "128Mi"
  redpanda_console_oauth2_proxy_trusted_proxy_ips = []

  redpanda_broker_cpu_request = "2"
  redpanda_broker_cpu_limit   = "2500m"
  redpanda_broker_mem_request = "5Gi"
  redpanda_broker_mem_limit   = "5Gi"

  # Keep Redpanda internal memory below the Kubernetes memory limit so the process
  # has headroom for non-Redpanda allocations inside the container.
  redpanda_enable_smp_memory_flags = true
  redpanda_smp                     = 2
  redpanda_memory                  = "3Gi"

  redpanda_config_renderer_cpu_request = "50m"
  redpanda_config_renderer_cpu_limit   = "200m"
  redpanda_config_renderer_mem_request = "64Mi"
  redpanda_config_renderer_mem_limit   = "64Mi"

  redpanda_console_cpu_request = "100m"
  redpanda_console_cpu_limit   = "500m"
  redpanda_console_mem_request = "256Mi"
  redpanda_console_mem_limit   = "512Mi"
}
