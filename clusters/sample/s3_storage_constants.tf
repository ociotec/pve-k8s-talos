locals {
  s3_namespace              = "s3"
  garage_name               = "garage"
  garage_node_k8s_label     = "s3"
  garage_data_host_path     = "/var/lib/s3"
  garage_storage_class_name = "s3-local"

  garage_s3_hostname                 = "s3.${local.domain}"
  garage_console_hostname            = "s3-console.${local.domain}"
  garage_s3_tls_secret_name          = "s3-api-tls"
  garage_console_tls_secret_name     = "s3-console-tls"
  garage_image                       = "dxflrs/garage:v2.2.0"
  garage_console_image               = "khairul169/garage-webui:1.1.0"
  garage_replication_factor          = 3
  garage_console_auth_keycloak_realm = "company"
  garage_console_auth_allowed_groups = ["k8s-admins"]

  garage_cpu_request = "500m"
  garage_cpu_limit   = "1"
  garage_mem_request = "1Gi"
  garage_mem_limit   = "1Gi"

  garage_console_cpu_request = "100m"
  garage_console_cpu_limit   = "500m"
  garage_console_mem_request = "256Mi"
  garage_console_mem_limit   = "256Mi"

  garage_oauth2_proxy_image_tag   = "v7.15.2"
  garage_oauth2_proxy_cpu_request = "50m"
  garage_oauth2_proxy_cpu_limit   = "200m"
  garage_oauth2_proxy_mem_request = "128Mi"
  garage_oauth2_proxy_mem_limit   = "128Mi"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = local.s3_namespace
      secret_name = local.garage_s3_tls_secret_name
    },
    {
      certificate = local.default_certificate_name
      namespace   = local.s3_namespace
      secret_name = local.garage_console_tls_secret_name
    },
  ]
}
