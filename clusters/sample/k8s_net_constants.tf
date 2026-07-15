locals {
  domain = "home.arpa"

  tls_source = "ca_issuer"

  # Public CA certificate path. When present, gen-talos-assets installs it into every
  # Talos node as a TrustedRootsConfig. Required for "preissued".
  root_ca_crt = "./certs/${local.domain}.pem"

  root_ca_common_name    = local.domain
  root_ca_organization   = "My home local network"
  root_ca_validity_hours = 876000 # 100 years
  root_ca_key            = "./certs/${local.domain}.key"

  metallb_pool_start = "192.168.1.70"
  metallb_pool_end   = "192.168.1.79"
  ingress_lb_ip      = "192.168.1.70"

  ingress_nginx_controller_cpu_request    = "100m"
  ingress_nginx_controller_cpu_limit      = "500m"
  ingress_nginx_controller_mem_request    = "512Mi"
  ingress_nginx_controller_mem_limit      = "512Mi"
  # Enable only after the monitoring OTLP collector is deployed.
  ingress_nginx_tracing_enabled       = false
  ingress_nginx_tracing_sampler_ratio = 0.10
  ingress_nginx_admission_job_cpu_request = "25m"
  ingress_nginx_admission_job_cpu_limit   = "200m"
  ingress_nginx_admission_job_mem_request = "64Mi"
  ingress_nginx_admission_job_mem_limit   = "64Mi"

  available_certificates = {
    wildcard_default = {
      cert_path = "./certs/wildcard.${local.domain}.fullchain.pem"
      key_path  = "./certs/wildcard.${local.domain}.key"
    }
  }
  default_certificate_name = "wildcard_default"

  # available_certificates is the catalog of installable certificate/key pairs.
  # Consumers such as monitoring or the Rook dashboard reference them by name.
}
