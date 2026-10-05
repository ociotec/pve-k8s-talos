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

  # Kyverno is absent unless exactly one mode is enabled for a cluster.
  enable_kyverno_audit   = false
  enable_kyverno_enforce = false

  metallb_controller_cpu_request = "50m"
  metallb_controller_cpu_limit   = "200m"
  metallb_controller_mem_request = "128Mi"
  metallb_controller_mem_limit   = "128Mi"
  metallb_speaker_cpu_request    = "50m"
  metallb_speaker_cpu_limit      = "200m"
  metallb_speaker_mem_request    = "128Mi"
  metallb_speaker_mem_limit      = "128Mi"

  ingress_nginx_controller_cpu_request = "100m"
  ingress_nginx_controller_cpu_limit   = "500m"
  ingress_nginx_controller_mem_request = "512Mi"
  ingress_nginx_controller_mem_limit   = "512Mi"
  # Optional ingress settings below show platform defaults; override only as needed.
  # Count and per-header buffer size are independent; large buffers are allocated on demand.
  # ingress_nginx_header_buffer_count = 4
  # ingress_nginx_header_buffer_size = "64k"
  # Serialize reloads to avoid accumulating retiring NGINX workers during bulk installs.
  # ingress_nginx_serial_reloads = true
  # Disable HPA to keep a fixed ingress_nginx_min_replicas count.
  # ingress_nginx_hpa_enabled = true
  # ingress_nginx_min_replicas = 3
  # ingress_nginx_max_replicas = 6
  # CPU utilization is relative to the controller CPU request, not its limit.
  # ingress_nginx_hpa_cpu_target_percentage = 70
  # Wait five minutes before scaling down, then remove at most one replica per minute.
  # ingress_nginx_hpa_scale_down_stabilization_seconds = 300
  # With HPA enabled, clean only Succeeded ingress Deployment pods after five minutes.
  # Both the schedule and retention default to five minutes without cluster overrides.
  # ingress_nginx_pod_cleanup_enabled = true
  # ingress_nginx_pod_cleanup_schedule = "*/5 * * * *"
  # ingress_nginx_pod_cleanup_retention_seconds = 300
  # ingress_nginx_pod_cleanup_image = "python:3.13-alpine"
  # ingress_nginx_pod_cleanup_cpu_request = "25m"
  # ingress_nginx_pod_cleanup_cpu_limit = "100m"
  # ingress_nginx_pod_cleanup_memory = "64Mi"
  # The OTLP collector is provided by the monitoring deployment.
  # Tracing is enabled by default. Uncomment to disable it.
  # ingress_nginx_tracing_enabled = false
  # The default sampler ratio is 1 so every request is traced. Uncomment to sample 10%.
  # ingress_nginx_tracing_sampler_ratio = 0.10
  ingress_nginx_admission_job_cpu_request = "25m"
  ingress_nginx_admission_job_cpu_limit   = "200m"
  ingress_nginx_admission_job_mem_request = "64Mi"
  ingress_nginx_admission_job_mem_limit   = "64Mi"

  # Automatic recovery for unreachable workers. The initial adapters use the
  # configured Proxmox VM inventory and Rook Ceph RBD network fencing.
  node_remediation_enabled = false

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
