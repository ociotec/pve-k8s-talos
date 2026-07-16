terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

variable "resources" {
  type = map(object({
    vcpus      = number
    memory     = number
    k8s_node   = string
    k8s_labels = optional(map(string), {})
    disks = list(object({
      size  = number
      mount = optional(string)
    }))
  }))
}

variable "vms" {
  type = map(object({
    node_name  = string
    vm_id      = number
    type       = string
    ip         = string
    ip2        = optional(string)
    k8s_labels = optional(map(string), {})
    vm_tags    = optional(string)
  }))
}

variable "constants" {
  type = any
}

data "terraform_remote_state" "identity" {
  count = trimspace(try(local.grafana_auth_keycloak_realm, "")) != "" || trimspace(try(local.prometheus_auth_keycloak_realm, "")) != "" || local.otlp_public_enabled_value ? 1 : 0

  backend = "local"
  config = {
    path = abspath("${path.root}/../identity/terraform.tfstate")
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  cluster_credentials                           = try(jsondecode(file("${path.module}/credentials.json")), {})
  monitoring_constants_source                   = file("${path.module}/constants.tf")
  monitoring_credentials                        = try(local.cluster_credentials.monitoring, {})
  monitoring_grafana_admin_password             = try(local.monitoring_credentials.grafana_admin_password, "")
  monitoring_grafana_postgres_password          = try(local.monitoring_credentials.grafana_postgres_password, "")
  monitoring_prometheus_api_basic_auth_password = try(local.monitoring_credentials.prometheus_api_basic_auth_password, "")
  monitoring_prometheus_api_basic_auth_hash     = try(local.monitoring_credentials.prometheus_api_basic_auth_hash, "")
  monitoring_prometheus_oauth_cookie_secret     = try(local.monitoring_credentials.prometheus_oauth_cookie_secret, "")
  prometheus_auth_keycloak_realm_value          = trimspace(try(local.prometheus_auth_keycloak_realm, ""))
  prometheus_auth_enabled                       = local.prometheus_auth_keycloak_realm_value != ""
  prometheus_auth_allowed_groups_value          = distinct(compact(try(local.prometheus_auth_allowed_groups, [])))
  prometheus_auth_ca_secret_name_value          = try(local.prometheus_auth_ca_secret_name, "prometheus-oauth-ca")
  prometheus_oauth_secret_name_value            = "prometheus-oauth"
  prometheus_oauth_redirect_uri                 = format("https://%s/oauth2/callback", local.prometheus_hostname)
  prometheus_oauth2_proxy_image_tag_value       = try(local.prometheus_oauth2_proxy_image_tag, "v7.12.0")
  prometheus_oauth2_proxy_cookie_name_value     = try(local.prometheus_oauth2_proxy_cookie_name, "_prometheus_oauth2_proxy")
  prometheus_oauth2_proxy_cpu_request_value     = try(local.prometheus_oauth2_proxy_cpu_request, "50m")
  prometheus_oauth2_proxy_cpu_limit_value       = try(local.prometheus_oauth2_proxy_cpu_limit, "200m")
  prometheus_oauth2_proxy_mem_request_value     = try(local.prometheus_oauth2_proxy_mem_request, "256Mi")
  prometheus_oauth2_proxy_mem_limit_value       = try(local.prometheus_oauth2_proxy_mem_limit, "256Mi")
  beyla_enabled_value = can(regex("(?m)^\\s*beyla_enabled\\s*=\\s*(true|false)\\s*$", local.monitoring_constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*beyla_enabled\\s*=\\s*(true|false)\\s*$", local.monitoring_constants_source)[0])
  ) : true
  beyla_image_tag_value = can(regex("(?m)^\\s*beyla_image_tag\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*beyla_image_tag\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "3.15.0"
  beyla_cpu_request_value = can(regex("(?m)^\\s*beyla_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*beyla_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "100m"
  beyla_cpu_limit_value = can(regex("(?m)^\\s*beyla_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*beyla_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "500m"
  beyla_mem_request_value = can(regex("(?m)^\\s*beyla_mem_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*beyla_mem_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "256Mi"
  beyla_mem_limit_value = can(regex("(?m)^\\s*beyla_mem_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*beyla_mem_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "256Mi"
  beyla_sampling_ratio_value = can(regex("(?m)^\\s*beyla_sampling_ratio\\s*=\\s*([0-9.]+)\\s*$", local.monitoring_constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*beyla_sampling_ratio\\s*=\\s*([0-9.]+)\\s*$", local.monitoring_constants_source)[0])
  ) : 0.10
  prometheus_auth_ca_content = local.prometheus_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  prometheus_auth_ca_enabled = trimspace(local.prometheus_auth_ca_content) != ""
  otlp_public_enabled_value = can(regex("(?m)^\\s*otlp_public_enabled\\s*=\\s*(true|false)\\s*$", local.monitoring_constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*otlp_public_enabled\\s*=\\s*(true|false)\\s*$", local.monitoring_constants_source)[0])
  ) : false
  otlp_public_hostname_value = can(regex("(?m)^\\s*otlp_public_hostname\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    replace(
      regex("(?m)^\\s*otlp_public_hostname\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0],
      "$${local.domain}",
      local.domain
    )
  ) : format("otlp.%s", local.domain)
  otlp_public_tls_secret_name_value = can(regex("(?m)^\\s*otlp_public_tls_secret_name\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_tls_secret_name\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "otlp-public-tls"
  otlp_public_keycloak_realm_value = can(regex("(?m)^\\s*otlp_public_keycloak_realm\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_keycloak_realm\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : ""
  otlp_public_cors_allowed_origins_value = distinct(compact([
    for origin in flatten([
      for match in regexall(
        "\"([^\"]+)\"",
        try(regex("(?m)^\\s*otlp_public_cors_allowed_origins\\s*=\\s*\\[([^]]*)\\]\\s*$", local.monitoring_constants_source)[0], "")
      ) : match
    ]) : replace(origin, "$${local.domain}", local.domain)
  ]))
  otlp_public_oidc_ca_content     = local.otlp_public_enabled_value ? try(file(local.root_ca_crt), "") : ""
  otlp_public_oidc_ca_enabled     = trimspace(local.otlp_public_oidc_ca_content) != ""
  otlp_public_oidc_ca_secret_name = "otlp-public-oidc-ca"
  otlp_public_collector_cpu_request_value = can(regex("(?m)^\\s*otlp_public_collector_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_collector_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "100m"
  otlp_public_collector_cpu_limit_value = can(regex("(?m)^\\s*otlp_public_collector_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_collector_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "500m"
  otlp_public_collector_mem_request_value = can(regex("(?m)^\\s*otlp_public_collector_mem_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_collector_mem_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "256Mi"
  otlp_public_collector_mem_limit_value = can(regex("(?m)^\\s*otlp_public_collector_mem_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]) ? (
    regex("(?m)^\\s*otlp_public_collector_mem_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.monitoring_constants_source)[0]
  ) : "256Mi"
  otlp_public_collector_memory_limit_mib_value = can(regex("(?m)^\\s*otlp_public_collector_memory_limit_mib\\s*=\\s*([0-9]+)\\s*$", local.monitoring_constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*otlp_public_collector_memory_limit_mib\\s*=\\s*([0-9]+)\\s*$", local.monitoring_constants_source)[0])
  ) : 192
  otlp_public_collector_memory_spike_mib_value = can(regex("(?m)^\\s*otlp_public_collector_memory_spike_mib\\s*=\\s*([0-9]+)\\s*$", local.monitoring_constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*otlp_public_collector_memory_spike_mib\\s*=\\s*([0-9]+)\\s*$", local.monitoring_constants_source)[0])
  ) : 64
  prometheus_api_hostname_value                   = trimspace(try(local.prometheus_api_hostname, "")) != "" ? trimspace(local.prometheus_api_hostname) : format("prometheus-api.%s", local.domain)
  prometheus_api_tls_secret_name_value            = try(local.prometheus_api_tls_secret_name, local.prometheus_tls_secret_name)
  prometheus_api_basic_auth_secret_name_value     = try(local.prometheus_api_basic_auth_secret_name, "prometheus-api-basic-auth")
  prometheus_api_basic_auth_user                  = "prometheus-external"
  prometheus_api_basic_auth_password_length_value = try(local.prometheus_api_basic_auth_password_length, 32)
  ceph_mode_value                                 = try(local.ceph_mode, "internal")
  ceph_external_value                             = try(local.ceph_external, {})
  ceph_prometheus_scheme_value                    = trimspace(try(local.ceph_external_value.prometheus_scheme, "http"))
  ceph_prometheus_targets = local.ceph_mode_value == "external" ? distinct(compact([
    for target in try(local.ceph_external_value.prometheus_targets, []) :
    trimsuffix(replace(replace(trimspace(target), "http://", ""), "https://", ""), "/")
  ])) : []

  grafana_auth_keycloak_realm_value                                = trimspace(try(local.grafana_auth_keycloak_realm, ""))
  grafana_auth_enabled                                             = local.grafana_auth_keycloak_realm_value != ""
  grafana_auth_view_groups_value                                   = distinct(compact(try(local.grafana_auth_view_groups, [])))
  grafana_auth_edit_groups_value                                   = distinct(compact(try(local.grafana_auth_edit_groups, [])))
  grafana_auth_name_value                                          = trimspace(try(local.grafana_auth_name, "Keycloak"))
  grafana_auth_scopes_value                                        = trimspace(try(local.grafana_auth_scopes, "openid profile email"))
  grafana_auth_auto_login_value                                    = try(local.grafana_auth_auto_login, false)
  grafana_auth_allow_sign_up_value                                 = try(local.grafana_auth_allow_sign_up, true)
  grafana_auth_ca_secret_name_value                                = try(local.grafana_auth_ca_secret_name, "grafana-oauth-ca")
  grafana_oauth_secret_name_value                                  = "grafana-oauth"
  grafana_db_name_value                                            = try(local.grafana_db_name, "grafana")
  grafana_db_username_value                                        = try(local.grafana_db_username, "grafana")
  grafana_postgres_image_tag_value                                 = try(local.grafana_postgres_image_tag, "18.3")
  grafana_postgres_pvc_size_value                                  = try(local.grafana_postgres_pvc_size, "8Gi")
  grafana_postgres_storage_class_value                             = local.grafana_postgres_storage_class
  grafana_postgres_password_length_value                           = try(local.grafana_postgres_password_length, 24)
  grafana_oauth_redirect_uri                                       = format("https://%s/login/generic_oauth", local.grafana_hostname)
  grafana_oauth_post_logout_uri                                    = format("https://%s/login", local.grafana_hostname)
  grafana_auth_ca_content                                          = local.grafana_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  grafana_auth_ca_enabled                                          = trimspace(local.grafana_auth_ca_content) != ""
  grafana_dashboard_provisioning_enabled_value                     = try(local.grafana_dashboard_provisioning_enabled, false)
  grafana_dashboard_provisioning_pvc_create_value                  = try(local.grafana_dashboard_provisioning_pvc_create, local.grafana_dashboard_provisioning_enabled_value)
  grafana_dashboard_provisioning_pvc_name_value                    = trimspace(try(local.grafana_dashboard_provisioning_pvc_name, "dashboards-provisioning"))
  grafana_dashboard_provisioning_pvc_storage_class_value           = trimspace(try(local.grafana_dashboard_provisioning_pvc_storage_class, local.grafana_storage_class))
  grafana_dashboard_provisioning_pvc_size_value                    = try(local.grafana_dashboard_provisioning_pvc_size, "1Gi")
  grafana_dashboard_provisioning_pvc_access_modes_value            = distinct(compact(try(local.grafana_dashboard_provisioning_pvc_access_modes, ["ReadWriteMany"])))
  grafana_dashboard_provisioning_pvc_update_interval_seconds_value = try(local.grafana_dashboard_provisioning_pvc_update_interval_seconds, 30)
  grafana_dashboard_provisioning_pvc_allow_ui_updates_value        = try(local.grafana_dashboard_provisioning_pvc_allow_ui_updates, false)
  grafana_dashboard_provisioning_pvc_disable_deletion_value        = try(local.grafana_dashboard_provisioning_pvc_disable_deletion, false)
  grafana_dashboard_provisioning_pvc_folders_from_files_structure_value = try(
    local.grafana_dashboard_provisioning_pvc_folders_from_files_structure,
    true
  )
  worker_vms = {
    for name, vm in var.vms : name => vm
    if try(var.resources[vm.type].k8s_node, "") == "worker"
  }
  worker_count            = length(local.worker_vms)
  total_worker_vcpu       = sum([for _, vm in local.worker_vms : var.resources[vm.type].vcpus])
  total_worker_memory_mib = sum([for _, vm in local.worker_vms : var.resources[vm.type].memory])
  total_worker_memory_gib = local.total_worker_memory_mib / 1024

  monitoring_baseline_worker_count      = 4
  monitoring_baseline_worker_vcpu       = 328
  monitoring_baseline_worker_memory_gib = 420

  monitoring_node_factor = max(
    1,
    local.worker_count > 0 ? local.worker_count / local.monitoring_baseline_worker_count : 1
  )
  monitoring_capacity_factor = max(
    1,
    local.total_worker_vcpu > 0 ? local.total_worker_vcpu / local.monitoring_baseline_worker_vcpu : 1,
    local.total_worker_memory_gib > 0 ? local.total_worker_memory_gib / local.monitoring_baseline_worker_memory_gib : 1
  )

  grafana_sizing_factor    = 0.75 * local.monitoring_node_factor + 0.25 * local.monitoring_capacity_factor
  prometheus_sizing_factor = 0.70 * local.monitoring_node_factor + 0.30 * local.monitoring_capacity_factor
  loki_sizing_factor       = 0.80 * local.monitoring_node_factor + 0.20 * local.monitoring_capacity_factor
  tempo_sizing_factor      = 0.80 * local.monitoring_node_factor + 0.20 * local.monitoring_capacity_factor

  grafana_cpu_request_effective_millicores = ceil(500 * local.grafana_sizing_factor / 10) * 10
  grafana_cpu_limit_effective_cores        = max(2, ceil(local.grafana_sizing_factor))
  grafana_mem_effective_mib                = ceil((1024 * local.grafana_sizing_factor) / 64) * 64

  # Reserve steady-state CPU proportionally and leave burst capacity for WAL replay and compaction.
  prometheus_cpu_request_effective_millicores = ceil(300 * local.prometheus_sizing_factor / 10) * 10
  prometheus_cpu_limit_effective_millicores = ceil(max(
    1500,
    1000 * local.prometheus_sizing_factor
  ) / 10) * 10
  # Prometheus' bundled auto-tuner floors fractional quotas; round up explicitly
  # so WAL replay and compaction can use the full CPU limit.
  prometheus_go_max_procs_value = tostring(ceil(local.prometheus_cpu_limit_effective_millicores / 1000))
  # Larger clusters accumulate more WAL and TSDB state, so startup replay needs
  # extra memory beyond steady-state scraping/query load.
  prometheus_wal_replay_headroom_mib = ceil((512 * max(0, local.monitoring_node_factor - 2)) / 64) * 64
  prometheus_mem_computed_mib = ceil((
    4096 +
    (1536 * (local.prometheus_sizing_factor - 1)) +
    local.prometheus_wal_replay_headroom_mib
  ) / 64) * 64
  prometheus_mem_effective_mib = max(6144, local.prometheus_mem_computed_mib)

  loki_cpu_request_value = "200m"
  loki_cpu_limit_value   = "1"
  loki_mem_effective_mib = ceil((1024 + (768 * (local.loki_sizing_factor - 1))) / 64) * 64

  tempo_cpu_request_effective_millicores = ceil(200 * local.tempo_sizing_factor / 10) * 10
  tempo_cpu_limit_effective_millicores   = ceil(max(1000, 1000 * local.tempo_sizing_factor) / 10) * 10
  tempo_mem_effective_mib                = ceil((1024 + (512 * (local.tempo_sizing_factor - 1))) / 64) * 64

  prometheus_storage_current_mib = can(regex("^[0-9]+Gi$", try(local.prometheus_storage_size, ""))) ? (
    tonumber(trimsuffix(local.prometheus_storage_size, "Gi")) * 1024
    ) : (
    can(regex("^[0-9]+Mi$", try(local.prometheus_storage_size, ""))) ? tonumber(trimsuffix(local.prometheus_storage_size, "Mi")) : 0
  )
  loki_storage_current_mib = can(regex("^[0-9]+Gi$", try(local.loki_storage_size, ""))) ? (
    tonumber(trimsuffix(local.loki_storage_size, "Gi")) * 1024
    ) : (
    can(regex("^[0-9]+Mi$", try(local.loki_storage_size, ""))) ? tonumber(trimsuffix(local.loki_storage_size, "Mi")) : 0
  )
  tempo_storage_current_mib = can(regex("^[0-9]+Gi$", try(local.tempo_storage_size, ""))) ? (
    tonumber(trimsuffix(local.tempo_storage_size, "Gi")) * 1024
    ) : (
    can(regex("^[0-9]+Mi$", try(local.tempo_storage_size, ""))) ? tonumber(trimsuffix(local.tempo_storage_size, "Mi")) : 0
  )

  prometheus_storage_formula_gib = ceil(60 * local.prometheus_sizing_factor)
  # Loki storage grows more softly than Prometheus so larger worker counts do not over-allocate log retention volume.
  loki_storage_formula_gib = ceil(40 * (1 + (0.75 * (local.loki_sizing_factor - 1))))
  # Trace volume depends primarily on application traffic and sampling, so this is a conservative floor, not a capacity forecast.
  tempo_storage_formula_gib = ceil(30 * (1 + (0.75 * (local.tempo_sizing_factor - 1))))

  prometheus_storage_effective_gib = max(local.prometheus_storage_formula_gib, ceil(local.prometheus_storage_current_mib / 1024))
  loki_storage_effective_gib       = max(local.loki_storage_formula_gib, ceil(local.loki_storage_current_mib / 1024))
  tempo_storage_effective_gib      = max(local.tempo_storage_formula_gib, ceil(local.tempo_storage_current_mib / 1024))

  grafana_cpu_request_value = local.grafana_cpu_request_effective_millicores % 1000 == 0 ? (
    format("%d", local.grafana_cpu_request_effective_millicores / 1000)
  ) : format("%dm", local.grafana_cpu_request_effective_millicores)
  grafana_cpu_limit_value = format("%d", local.grafana_cpu_limit_effective_cores)
  grafana_mem_request_value = local.grafana_mem_effective_mib % 1024 == 0 ? (
    format("%dGi", local.grafana_mem_effective_mib / 1024)
  ) : format("%dMi", local.grafana_mem_effective_mib)
  grafana_mem_limit_value = local.grafana_mem_request_value

  prometheus_cpu_request_value = local.prometheus_cpu_request_effective_millicores % 1000 == 0 ? (
    format("%d", local.prometheus_cpu_request_effective_millicores / 1000)
  ) : format("%dm", local.prometheus_cpu_request_effective_millicores)
  prometheus_cpu_limit_value = local.prometheus_cpu_limit_effective_millicores % 1000 == 0 ? (
    format("%d", local.prometheus_cpu_limit_effective_millicores / 1000)
  ) : format("%dm", local.prometheus_cpu_limit_effective_millicores)
  prometheus_mem_request_value = local.prometheus_mem_effective_mib % 1024 == 0 ? (
    format("%dGi", local.prometheus_mem_effective_mib / 1024)
  ) : format("%dMi", local.prometheus_mem_effective_mib)
  prometheus_mem_limit_value    = local.prometheus_mem_request_value
  prometheus_storage_size_value = format("%dGi", local.prometheus_storage_effective_gib)
  prometheus_startup_probe_failure_threshold_value = ceil((
    900 + (120 * max(0, local.monitoring_node_factor - 1))
  ) / 5)
  prometheus_query_max_concurrency_value = min(
    18,
    10 + (2 * max(0, floor(local.prometheus_sizing_factor - 1)))
  )

  loki_mem_request_value = local.loki_mem_effective_mib % 1024 == 0 ? (
    format("%dGi", local.loki_mem_effective_mib / 1024)
  ) : format("%dMi", local.loki_mem_effective_mib)
  loki_mem_limit_value    = local.loki_mem_request_value
  loki_storage_size_value = format("%dGi", local.loki_storage_effective_gib)

  tempo_cpu_request_value = local.tempo_cpu_request_effective_millicores % 1000 == 0 ? (
    format("%d", local.tempo_cpu_request_effective_millicores / 1000)
  ) : format("%dm", local.tempo_cpu_request_effective_millicores)
  tempo_cpu_limit_value = local.tempo_cpu_limit_effective_millicores % 1000 == 0 ? (
    format("%d", local.tempo_cpu_limit_effective_millicores / 1000)
  ) : format("%dm", local.tempo_cpu_limit_effective_millicores)
  tempo_mem_request_value = local.tempo_mem_effective_mib % 1024 == 0 ? (
    format("%dGi", local.tempo_mem_effective_mib / 1024)
  ) : format("%dMi", local.tempo_mem_effective_mib)
  tempo_mem_limit_value    = local.tempo_mem_request_value
  tempo_storage_size_value = format("%dGi", local.tempo_storage_effective_gib)

  grafana_go_mem_limit_percent_value = try(local.grafana_go_mem_limit_percent, 90)
  grafana_mem_limit_mib = can(regex("^[0-9]+Gi$", local.grafana_mem_limit_value)) ? tonumber(trimsuffix(local.grafana_mem_limit_value, "Gi")) * 1024 : (
    can(regex("^[0-9]+Mi$", local.grafana_mem_limit_value)) ? tonumber(trimsuffix(local.grafana_mem_limit_value, "Mi")) : null
  )
  grafana_go_mem_limit_mib         = floor(local.grafana_mem_limit_mib * local.grafana_go_mem_limit_percent_value / 100)
  grafana_go_mem_limit             = format("%dMiB", local.grafana_go_mem_limit_mib)
  monitoring_keycloak_auth_enabled = local.grafana_auth_enabled || local.prometheus_auth_enabled || local.otlp_public_enabled_value
  identity_realm_groups = local.monitoring_keycloak_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_realm_groups,
    {}
  ) : {}
  identity_oidc_metadata = local.monitoring_keycloak_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_metadata,
    {}
  ) : {}
  identity_oidc_client_secrets = try(local.cluster_credentials.identity.oidc_client_secrets, {})
  otlp_public_oidc_issuer_value = local.otlp_public_enabled_value ? try(
    local.identity_oidc_metadata[local.otlp_public_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  grafana_oidc_issuer = local.grafana_auth_enabled ? try(
    local.identity_oidc_metadata[local.grafana_auth_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  grafana_oidc_client_id = local.grafana_auth_enabled ? try(
    local.identity_oidc_metadata[local.grafana_auth_keycloak_realm_value].clients["grafana"].client_id,
    ""
  ) : ""
  grafana_oidc_client_secret = local.grafana_auth_enabled ? try(
    local.identity_oidc_client_secrets[format("%s/grafana", local.grafana_auth_keycloak_realm_value)],
    ""
  ) : ""
  prometheus_oidc_issuer = local.prometheus_auth_enabled ? try(
    local.identity_oidc_metadata[local.prometheus_auth_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  prometheus_oidc_client_id = local.prometheus_auth_enabled ? try(
    local.identity_oidc_metadata[local.prometheus_auth_keycloak_realm_value].clients["prometheus"].client_id,
    ""
  ) : ""
  prometheus_oidc_client_secret = local.prometheus_auth_enabled ? try(
    local.identity_oidc_client_secrets[format("%s/prometheus", local.prometheus_auth_keycloak_realm_value)],
    ""
  ) : ""
  grafana_oidc_auth_url  = local.grafana_oidc_issuer != "" ? format("%s/protocol/openid-connect/auth", local.grafana_oidc_issuer) : ""
  grafana_oidc_token_url = local.grafana_oidc_issuer != "" ? format("%s/protocol/openid-connect/token", local.grafana_oidc_issuer) : ""
  grafana_oidc_api_url   = local.grafana_oidc_issuer != "" ? format("%s/protocol/openid-connect/userinfo", local.grafana_oidc_issuer) : ""
  grafana_oidc_jwk_set_url = local.grafana_oidc_issuer != "" ? format(
    "%s/protocol/openid-connect/certs",
    local.grafana_oidc_issuer
  ) : ""
  grafana_oidc_end_session_url = local.grafana_oidc_issuer != "" ? format("%s/protocol/openid-connect/logout", local.grafana_oidc_issuer) : ""
  grafana_oauth_signout_redirect_url = local.grafana_oidc_end_session_url != "" ? format(
    "%s?client_id=%s&post_logout_redirect_uri=%s",
    local.grafana_oidc_end_session_url,
    urlencode(local.grafana_oidc_client_id),
    urlencode(local.grafana_oauth_post_logout_uri)
  ) : ""
  grafana_auth_effective_view_groups = distinct(compact(concat(
    local.grafana_auth_view_groups_value,
    flatten([
      for group_name in local.grafana_auth_view_groups_value : [
        for ldap_group in try(local.identity_realm_groups[local.grafana_auth_keycloak_realm_value][group_name].included_ldap_groups, []) : ldap_group.group_name
      ]
    ])
  )))
  grafana_auth_effective_edit_groups = distinct(compact(concat(
    local.grafana_auth_edit_groups_value,
    flatten([
      for group_name in local.grafana_auth_edit_groups_value : [
        for ldap_group in try(local.identity_realm_groups[local.grafana_auth_keycloak_realm_value][group_name].included_ldap_groups, []) : ldap_group.group_name
      ]
    ])
  )))
  grafana_auth_allowed_groups = distinct(concat(
    local.grafana_auth_effective_view_groups,
    local.grafana_auth_effective_edit_groups
  ))
  prometheus_auth_effective_allowed_groups = distinct(compact(concat(
    local.prometheus_auth_allowed_groups_value,
    flatten([
      for group_name in local.prometheus_auth_allowed_groups_value : [
        for ldap_group in try(local.identity_realm_groups[local.prometheus_auth_keycloak_realm_value][group_name].included_ldap_groups, []) : ldap_group.group_name
      ]
    ])
  )))
  grafana_auth_view_group_condition = length(local.grafana_auth_effective_view_groups) > 0 ? join(" || ", [
    for group_name in local.grafana_auth_effective_view_groups : format("contains(groups[*], '%s')", replace(group_name, "'", "\\'"))
  ]) : "false"
  grafana_auth_edit_group_condition = length(local.grafana_auth_effective_edit_groups) > 0 ? join(" || ", [
    for group_name in local.grafana_auth_effective_edit_groups : format("contains(groups[*], '%s')", replace(group_name, "'", "\\'"))
  ]) : "false"
  grafana_auth_role_attribute_path = format(
    "(%s) && 'Editor' || (%s) && 'Viewer' || 'None'",
    local.grafana_auth_edit_group_condition,
    local.grafana_auth_view_group_condition
  )
  missing_grafana_auth_group_definitions = local.grafana_auth_enabled ? [
    for group_name in distinct(concat(local.grafana_auth_view_groups_value, local.grafana_auth_edit_groups_value)) : group_name
    if !contains(keys(try(local.identity_realm_groups[local.grafana_auth_keycloak_realm_value], {})), group_name)
  ] : []
  missing_prometheus_auth_group_definitions = local.prometheus_auth_enabled ? [
    for group_name in local.prometheus_auth_allowed_groups_value : group_name
    if !contains(keys(try(local.identity_realm_groups[local.prometheus_auth_keycloak_realm_value], {})), group_name)
  ] : []
  available_identity_realms = keys(local.identity_oidc_metadata)
  monitoring_tls_secrets = concat(
    local.tls_secrets,
    local.otlp_public_enabled_value ? [{
      certificate = local.default_certificate_name
      namespace   = "monitoring"
      secret_name = local.otlp_public_tls_secret_name_value
    }] : []
  )
  monitoring_namespace    = yamldecode(file("${path.module}/namespace.yaml"))
  grafana_dashboard_files = sort(fileset("${path.module}/grafana/dashboards", "**/*.json"))
  grafana_dashboard_configmap_keys = {
    for filename in local.grafana_dashboard_files :
    filename => replace(filename, "/", "__")
  }
  grafana_dashboard_directories = sort(distinct([
    for filename in local.grafana_dashboard_files : dirname(filename)
  ]))
  grafana_dashboard_configmaps = {
    for directory in local.grafana_dashboard_directories :
    replace(directory, "/", "-") => {
      name = "grafana-dashboards-${replace(directory, "/", "-")}"
      dir  = directory
      files = {
        for filename in local.grafana_dashboard_files :
        filename => local.grafana_dashboard_configmap_keys[filename]
        if dirname(filename) == directory
      }
    }
  }
  grafana_dashboard_root_group      = "infrastructure"
  grafana_dashboard_root_mount_path = "/var/lib/grafana/dashboards/infrastructure-root"
  grafana_dashboard_root_source = {
    name = local.grafana_dashboard_configmaps[local.grafana_dashboard_root_group].name
    items = [
      for filename, key in local.grafana_dashboard_configmaps[local.grafana_dashboard_root_group].files : {
        key  = key
        path = basename(filename)
      }
    ]
  }
  grafana_dashboard_group_sources = [
    for group, configmap in local.grafana_dashboard_configmaps : {
      volume_name    = "dashboards-${group}"
      configmap_name = configmap.name
      mount_path     = "/var/lib/grafana/dashboards/${configmap.dir}"
      items = [
        for filename, key in configmap.files : {
          key  = key
          path = basename(filename)
        }
      ]
    }
    if group != local.grafana_dashboard_root_group
  ]
  grafana_dashboard_sync_hash = substr(sha256(join("", concat(
    [file("${path.module}/grafana.yaml")],
    [file("${path.module}/grafana/grafana.yaml")],
    [
      tostring(local.grafana_dashboard_provisioning_enabled_value),
      local.grafana_dashboard_provisioning_pvc_name_value,
      local.grafana_dashboard_provisioning_pvc_storage_class_value,
      local.grafana_dashboard_provisioning_pvc_size_value,
      join(",", local.grafana_dashboard_provisioning_pvc_access_modes_value),
    ],
    [
      for filename in local.grafana_dashboard_files :
      file("${path.module}/grafana/dashboards/${filename}")
    ]
  ))), 0, 12)
  prometheus_storage_class_value          = local.prometheus_storage_class
  prometheus_wal_compression_value        = try(local.prometheus_wal_compression, true)
  prometheus_retention_size_percent_value = try(local.prometheus_retention_size_percent, 80)
  prometheus_storage_size_mib = can(regex("^[0-9]+Gi$", local.prometheus_storage_size_value)) ? tonumber(trimsuffix(local.prometheus_storage_size_value, "Gi")) * 1024 : (
    can(regex("^[0-9]+Mi$", local.prometheus_storage_size_value)) ? tonumber(trimsuffix(local.prometheus_storage_size_value, "Mi")) : null
  )
  prometheus_retention_size_mib         = local.prometheus_storage_size_mib == null ? null : floor(local.prometheus_storage_size_mib * local.prometheus_retention_size_percent_value / 100)
  prometheus_retention_size             = local.prometheus_retention_size_mib == null ? "" : format("%dMB", local.prometheus_retention_size_mib)
  prometheus_go_mem_limit_percent_value = try(local.prometheus_go_mem_limit_percent, 80)
  prometheus_mem_limit_mib = can(regex("^[0-9]+Gi$", local.prometheus_mem_limit_value)) ? tonumber(trimsuffix(local.prometheus_mem_limit_value, "Gi")) * 1024 : (
    can(regex("^[0-9]+Mi$", local.prometheus_mem_limit_value)) ? tonumber(trimsuffix(local.prometheus_mem_limit_value, "Mi")) : null
  )
  prometheus_go_mem_limit_mib               = floor(local.prometheus_mem_limit_mib * local.prometheus_go_mem_limit_percent_value / 100)
  prometheus_go_mem_limit                   = format("%dMiB", local.prometheus_go_mem_limit_mib)
  prometheus_wal_recovery_cpu_request_value = "50m"
  prometheus_wal_recovery_cpu_limit_value   = "200m"
  prometheus_wal_recovery_mem_request_value = "128Mi"
  prometheus_wal_recovery_mem_limit_value   = "128Mi"
  # registry.k8s.io/kubectl and rancher/kubectl are distroless and cannot run the mounted shell scripts.
  prometheus_wal_recovery_kubectl_image = "dtzar/helm-kubectl:3.19.0"
  prometheus_wal_check_and_recovery_scripts = {
    "prometheus-wal-check-and-recovery.sh" = file("${path.module}/scripts/prometheus-wal-check-and-recovery.sh")
    "prometheus-wal-cleanup.sh"            = file("${path.module}/scripts/prometheus-wal-cleanup.sh")
  }
  prometheus_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/prometheus.yaml", {
      storage_class                              = local.prometheus_storage_class_value
      prometheus_storage_size                    = local.prometheus_storage_size_value
      prometheus_retention                       = local.prometheus_retention
      prometheus_retention_size                  = local.prometheus_retention_size
      prometheus_image_tag                       = local.prometheus_image_tag
      prometheus_hostname                        = local.prometheus_hostname
      prometheus_api_hostname                    = local.prometheus_api_hostname_value
      prometheus_cpu_request                     = local.prometheus_cpu_request_value
      prometheus_cpu_limit                       = local.prometheus_cpu_limit_value
      prometheus_go_max_procs                    = local.prometheus_go_max_procs_value
      prometheus_mem_request                     = local.prometheus_mem_request_value
      prometheus_mem_limit                       = local.prometheus_mem_limit_value
      prometheus_go_mem_limit                    = local.prometheus_go_mem_limit
      prometheus_go_gc_percent                   = tostring(try(local.prometheus_go_gc_percent, 50))
      prometheus_startup_probe_failure_threshold = local.prometheus_startup_probe_failure_threshold_value
      prometheus_wal_compression                 = local.prometheus_wal_compression_value
      prometheus_query_max_concurrency           = local.prometheus_query_max_concurrency_value
      prometheus_wal_recovery_cpu_request        = local.prometheus_wal_recovery_cpu_request_value
      prometheus_wal_recovery_cpu_limit          = local.prometheus_wal_recovery_cpu_limit_value
      prometheus_wal_recovery_mem_request        = local.prometheus_wal_recovery_mem_request_value
      prometheus_wal_recovery_mem_limit          = local.prometheus_wal_recovery_mem_limit_value
      prometheus_wal_recovery_kubectl_image      = local.prometheus_wal_recovery_kubectl_image
      prometheus_wal_check_and_recovery_scripts  = local.prometheus_wal_check_and_recovery_scripts
      prometheus_tls_secret_name                 = local.prometheus_tls_secret_name
      prometheus_auth_enabled                    = local.prometheus_auth_enabled
      prometheus_auth_ca_enabled                 = local.prometheus_auth_ca_enabled
      prometheus_auth_ca_secret_name             = local.prometheus_auth_ca_secret_name_value
      prometheus_oauth_secret_name               = local.prometheus_oauth_secret_name_value
      prometheus_oidc_issuer                     = local.prometheus_oidc_issuer
      prometheus_oidc_client_id                  = local.prometheus_oidc_client_id
      prometheus_oauth_redirect_uri              = local.prometheus_oauth_redirect_uri
      prometheus_oauth2_proxy_image_tag          = local.prometheus_oauth2_proxy_image_tag_value
      prometheus_oauth2_proxy_cookie_name        = local.prometheus_oauth2_proxy_cookie_name_value
      prometheus_oauth2_proxy_allowed_groups     = local.prometheus_auth_effective_allowed_groups
      prometheus_oauth2_proxy_cpu_request        = local.prometheus_oauth2_proxy_cpu_request_value
      prometheus_oauth2_proxy_cpu_limit          = local.prometheus_oauth2_proxy_cpu_limit_value
      prometheus_oauth2_proxy_mem_request        = local.prometheus_oauth2_proxy_mem_request_value
      prometheus_oauth2_proxy_mem_limit          = local.prometheus_oauth2_proxy_mem_limit_value
      ceph_prometheus_targets                    = local.ceph_prometheus_targets
      ceph_prometheus_scheme                     = local.ceph_prometheus_scheme_value
      ceph_cluster_name                          = try(local.ceph_cluster_name, "rook-ceph")
      ceph_namespace                             = try(local.ceph_namespace, "rook-ceph")
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  prometheus_api_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/prometheus-api.yaml", {
      prometheus_api_hostname               = local.prometheus_api_hostname_value
      prometheus_api_tls_secret_name        = local.prometheus_api_tls_secret_name_value
      prometheus_api_basic_auth_secret_name = local.prometheus_api_basic_auth_secret_name_value
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  grafana_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/grafana.yaml", {
      storage_class                       = local.grafana_storage_class
      grafana_storage_size                = local.grafana_storage_size
      grafana_image_tag                   = local.grafana_image_tag
      grafana_hostname                    = local.grafana_hostname
      grafana_db_name                     = local.grafana_db_name_value
      grafana_db_username                 = local.grafana_db_username_value
      grafana_postgres_image_tag          = local.grafana_postgres_image_tag_value
      grafana_postgres_exporter_image_tag = local.grafana_postgres_exporter_image_tag
      grafana_postgres_pvc_size           = local.grafana_postgres_pvc_size_value
      grafana_postgres_max_connections    = "150"
      grafana_postgres_storage_class      = local.grafana_postgres_storage_class_value
      grafana_postgres_cpu_request        = try(local.grafana_postgres_cpu_request, "100m")
      grafana_postgres_cpu_limit          = try(local.grafana_postgres_cpu_limit, "500m")
      grafana_postgres_mem_request        = try(local.grafana_postgres_mem_request, "256Mi")
      grafana_postgres_mem_limit          = try(local.grafana_postgres_mem_limit, "256Mi")
      grafana_wait_for_postgres_cpu_request = try(
        local.grafana_wait_for_postgres_cpu_request,
        "20m"
      )
      grafana_wait_for_postgres_cpu_limit = try(
        local.grafana_wait_for_postgres_cpu_limit,
        "100m"
      )
      grafana_wait_for_postgres_mem_request = try(
        local.grafana_wait_for_postgres_mem_request,
        "32Mi"
      )
      grafana_wait_for_postgres_mem_limit = try(
        local.grafana_wait_for_postgres_mem_limit,
        "32Mi"
      )
      grafana_cpu_request                       = local.grafana_cpu_request_value
      grafana_cpu_limit                         = local.grafana_cpu_limit_value
      grafana_mem_request                       = local.grafana_mem_request_value
      grafana_mem_limit                         = local.grafana_mem_limit_value
      grafana_db_max_open_conn                  = "20"
      grafana_go_mem_limit                      = local.grafana_go_mem_limit
      grafana_go_gc_percent                     = tostring(try(local.grafana_go_gc_percent, 50))
      grafana_tls_secret_name                   = local.grafana_tls_secret_name
      grafana_auth_enabled                      = local.grafana_auth_enabled
      grafana_auth_ca_enabled                   = local.grafana_auth_ca_enabled
      grafana_auth_ca_secret_name               = local.grafana_auth_ca_secret_name_value
      grafana_oauth_secret_name                 = local.grafana_oauth_secret_name_value
      grafana_auth_name                         = local.grafana_auth_name_value
      grafana_auth_scopes                       = local.grafana_auth_scopes_value
      grafana_auth_auto_login                   = tostring(local.grafana_auth_auto_login_value)
      grafana_auth_allow_sign_up                = tostring(local.grafana_auth_allow_sign_up_value)
      grafana_auth_allowed_groups               = join(",", local.grafana_auth_allowed_groups)
      grafana_auth_role_attribute_path          = local.grafana_auth_role_attribute_path
      grafana_oidc_client_id                    = local.grafana_oidc_client_id
      grafana_oidc_auth_url                     = local.grafana_oidc_auth_url
      grafana_oidc_token_url                    = local.grafana_oidc_token_url
      grafana_oidc_api_url                      = local.grafana_oidc_api_url
      grafana_oidc_jwk_set_url                  = local.grafana_oidc_jwk_set_url
      grafana_oauth_signout_redirect_url        = local.grafana_oauth_signout_redirect_url
      grafana_dashboard_root_source             = local.grafana_dashboard_root_source
      grafana_dashboard_root_mount_path         = local.grafana_dashboard_root_mount_path
      grafana_dashboard_group_sources           = local.grafana_dashboard_group_sources
      grafana_dashboard_sync_hash               = local.grafana_dashboard_sync_hash
      grafana_dashboard_provisioning_enabled    = local.grafana_dashboard_provisioning_enabled_value
      grafana_dashboard_provisioning_pvc_create = local.grafana_dashboard_provisioning_pvc_create_value
      grafana_dashboard_provisioning_pvc_name   = local.grafana_dashboard_provisioning_pvc_name_value
      grafana_dashboard_provisioning_pvc_storage_class = (
        local.grafana_dashboard_provisioning_pvc_storage_class_value
      )
      grafana_dashboard_provisioning_pvc_size         = local.grafana_dashboard_provisioning_pvc_size_value
      grafana_dashboard_provisioning_pvc_access_modes = local.grafana_dashboard_provisioning_pvc_access_modes_value
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  loki_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/loki.yaml", {
      storage_class     = local.loki_storage_class
      loki_storage_size = local.loki_storage_size_value
      loki_retention    = local.loki_retention
      loki_image_tag    = local.loki_image_tag
      loki_cpu_request  = local.loki_cpu_request_value
      loki_cpu_limit    = local.loki_cpu_limit_value
      loki_mem_request  = local.loki_mem_request_value
      loki_mem_limit    = local.loki_mem_limit_value
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  tempo_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/tempo.yaml", {
      storage_class                   = local.tempo_storage_class
      tempo_storage_size              = local.tempo_storage_size_value
      tempo_retention                 = local.tempo_retention
      tempo_image_tag                 = local.tempo_image_tag
      tempo_cpu_request               = local.tempo_cpu_request_value
      tempo_cpu_limit                 = local.tempo_cpu_limit_value
      tempo_mem_request               = local.tempo_mem_request_value
      tempo_mem_limit                 = local.tempo_mem_limit_value
      otel_collector_image_tag        = local.otel_collector_image_tag
      otel_collector_cpu_request      = local.otel_collector_cpu_request
      otel_collector_cpu_limit        = local.otel_collector_cpu_limit
      otel_collector_mem_request      = local.otel_collector_mem_request
      otel_collector_mem_limit        = local.otel_collector_mem_limit
      otel_collector_memory_limit_mib = local.otel_collector_memory_limit_mib
      otel_collector_memory_spike_mib = local.otel_collector_memory_spike_mib
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  otlp_public_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/otlp-public.yaml", {
      otlp_public_hostname                   = local.otlp_public_hostname_value
      otlp_public_tls_secret_name            = local.otlp_public_tls_secret_name_value
      otlp_public_oidc_issuer                = local.otlp_public_oidc_issuer_value
      otlp_public_cors_allowed_origins       = local.otlp_public_cors_allowed_origins_value
      otlp_public_oidc_ca_enabled            = local.otlp_public_oidc_ca_enabled
      otlp_public_oidc_ca_secret_name        = local.otlp_public_oidc_ca_secret_name
      otlp_public_collector_image_tag        = local.otel_collector_image_tag
      otlp_public_collector_cpu_request      = local.otlp_public_collector_cpu_request_value
      otlp_public_collector_cpu_limit        = local.otlp_public_collector_cpu_limit_value
      otlp_public_collector_mem_request      = local.otlp_public_collector_mem_request_value
      otlp_public_collector_mem_limit        = local.otlp_public_collector_mem_limit_value
      otlp_public_collector_memory_limit_mib = local.otlp_public_collector_memory_limit_mib_value
      otlp_public_collector_memory_spike_mib = local.otlp_public_collector_memory_spike_mib_value
    })) :
    yamldecode(doc)
    if local.otlp_public_enabled_value && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  beyla_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/beyla.yaml", {
      beyla_image_tag      = local.beyla_image_tag_value
      beyla_cpu_request    = local.beyla_cpu_request_value
      beyla_cpu_limit      = local.beyla_cpu_limit_value
      beyla_mem_request    = local.beyla_mem_request_value
      beyla_mem_limit      = local.beyla_mem_limit_value
      beyla_sampling_ratio = local.beyla_sampling_ratio_value
    })) :
    yamldecode(doc)
    if local.beyla_enabled_value && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  promtail_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/promtail.yaml", {
      promtail_image_tag   = local.promtail_image_tag
      promtail_cpu_request = local.promtail_cpu_request
      promtail_cpu_limit   = local.promtail_cpu_limit
      promtail_mem_request = local.promtail_mem_request
      promtail_mem_limit   = local.promtail_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  kube_state_metrics_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/kube-state-metrics.yaml", {
      kube_state_metrics_image_tag   = local.kube_state_metrics_image_tag
      kube_state_metrics_cpu_request = local.kube_state_metrics_cpu_request
      kube_state_metrics_cpu_limit   = local.kube_state_metrics_cpu_limit
      kube_state_metrics_mem_request = local.kube_state_metrics_mem_request
      kube_state_metrics_mem_limit   = local.kube_state_metrics_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  node_exporter_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/node-exporter.yaml", {
      node_exporter_image_tag   = local.node_exporter_image_tag
      node_exporter_cpu_request = local.node_exporter_cpu_request
      node_exporter_cpu_limit   = local.node_exporter_cpu_limit
      node_exporter_mem_request = local.node_exporter_mem_request
      node_exporter_mem_limit   = local.node_exporter_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  prometheus_oauth2_proxy_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/prometheus-oauth2-proxy.yaml", {
      prometheus_hostname                    = local.prometheus_hostname
      prometheus_tls_secret_name             = local.prometheus_tls_secret_name
      prometheus_auth_ca_enabled             = local.prometheus_auth_ca_enabled
      prometheus_auth_ca_secret_name         = local.prometheus_auth_ca_secret_name_value
      prometheus_oauth_secret_name           = local.prometheus_oauth_secret_name_value
      prometheus_oidc_issuer                 = local.prometheus_oidc_issuer
      prometheus_oidc_client_id              = local.prometheus_oidc_client_id
      prometheus_oauth_redirect_uri          = local.prometheus_oauth_redirect_uri
      prometheus_oauth2_proxy_image_tag      = local.prometheus_oauth2_proxy_image_tag_value
      prometheus_oauth2_proxy_cookie_name    = local.prometheus_oauth2_proxy_cookie_name_value
      prometheus_oauth2_proxy_allowed_groups = local.prometheus_auth_effective_allowed_groups
      prometheus_oauth2_proxy_cpu_request    = local.prometheus_oauth2_proxy_cpu_request_value
      prometheus_oauth2_proxy_cpu_limit      = local.prometheus_oauth2_proxy_cpu_limit_value
      prometheus_oauth2_proxy_mem_request    = local.prometheus_oauth2_proxy_mem_request_value
      prometheus_oauth2_proxy_mem_limit      = local.prometheus_oauth2_proxy_mem_limit_value
    })) :
    yamldecode(doc)
    if local.prometheus_auth_enabled && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]

  monitoring_resources = concat(
    local.prometheus_manifests,
    local.prometheus_api_manifests,
    local.grafana_manifests,
    local.loki_manifests,
    local.tempo_manifests,
    local.otlp_public_manifests,
    local.beyla_manifests,
    local.promtail_manifests,
    [
      {
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = "grafana-dashboard-provider"
          namespace = "monitoring"
        }
        data = {
          "provider.yaml" = templatefile("${path.module}/grafana/grafana.yaml", {
            grafana_dashboard_provisioning_enabled                     = local.grafana_dashboard_provisioning_enabled_value
            grafana_dashboard_provisioning_pvc_update_interval_seconds = local.grafana_dashboard_provisioning_pvc_update_interval_seconds_value
            grafana_dashboard_provisioning_pvc_allow_ui_updates        = local.grafana_dashboard_provisioning_pvc_allow_ui_updates_value
            grafana_dashboard_provisioning_pvc_disable_deletion        = local.grafana_dashboard_provisioning_pvc_disable_deletion_value
            grafana_dashboard_provisioning_pvc_folders_from_files_structure = (
              local.grafana_dashboard_provisioning_pvc_folders_from_files_structure_value
            )
          })
        }
      },
    ],
    [
      for group, configmap in local.grafana_dashboard_configmaps : {
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = configmap.name
          namespace = "monitoring"
        }
        data = {
          for filename, key in configmap.files :
          key => file("${path.module}/grafana/dashboards/${filename}")
        }
      }
    ],
    local.kube_state_metrics_manifests,
    local.node_exporter_manifests,
    local.prometheus_oauth2_proxy_manifests
  )

  monitoring_certificates = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  monitoring_ingress = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  monitoring_other = [
    for m in local.monitoring_resources : m
    if !contains(["Certificate", "Ingress", "Namespace", "DaemonSet", "Job"], try(m.kind, ""))
  ]
  monitoring_daemonsets = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "DaemonSet"
  ]
  monitoring_jobs = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Job"
  ]
  extra_namespaces = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Namespace"
  ]

  preissued_tls_secrets_by_target = {
    for secret in local.monitoring_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" ? [
    for secret in local.monitoring_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)
  ] : []
  missing_preissued_tls_secret_targets = [
    for target in local.expected_preissued_tls_secret_targets : target
    if !contains(keys(local.preissued_tls_secrets_by_target), target)
  ]
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

check "preissued_tls_secrets_unique" {
  assert {
    condition     = local.tls_source != "preissued" || length(local.monitoring_tls_secrets) == length(local.preissued_tls_secrets_by_target)
    error_message = "tls_secrets contains duplicate namespace/secret_name pairs."
  }
}

check "preissued_tls_secrets_required" {
  assert {
    condition     = local.tls_source != "preissued" || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued_tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

check "grafana_dashboard_provisioning_pvc_required" {
  assert {
    condition = !local.grafana_dashboard_provisioning_enabled_value || (
      local.grafana_dashboard_provisioning_pvc_name_value != "" &&
      local.grafana_dashboard_provisioning_pvc_storage_class_value != "" &&
      local.grafana_dashboard_provisioning_pvc_size_value != "" &&
      length(local.grafana_dashboard_provisioning_pvc_access_modes_value) > 0
    )
    error_message = "Dashboard provisioning PVC requires grafana_dashboard_provisioning_pvc_name, grafana_dashboard_provisioning_pvc_storage_class, grafana_dashboard_provisioning_pvc_size, and at least one access mode."
  }
}

check "grafana_go_memory_limit_supported" {
  assert {
    condition     = local.grafana_mem_limit_mib != null
    error_message = format("grafana_mem_limit must use a supported whole-number memory unit for GOMEMLIMIT derivation: Mi or Gi. Got %q.", local.grafana_mem_limit_value)
  }
}

check "grafana_go_mem_limit_percent_valid" {
  assert {
    condition     = local.grafana_go_mem_limit_percent_value > 0 && local.grafana_go_mem_limit_percent_value < 100
    error_message = format("grafana_go_mem_limit_percent must be greater than 0 and less than 100. Got %s.", tostring(local.grafana_go_mem_limit_percent_value))
  }
}

check "prometheus_go_memory_limit_supported" {
  assert {
    condition     = local.prometheus_mem_limit_mib != null
    error_message = format("prometheus_mem_limit must use a supported whole-number memory unit for GOMEMLIMIT derivation: Mi or Gi. Got %q.", local.prometheus_mem_limit_value)
  }
}

check "prometheus_go_mem_limit_percent_valid" {
  assert {
    condition     = local.prometheus_go_mem_limit_percent_value > 0 && local.prometheus_go_mem_limit_percent_value < 100
    error_message = format("prometheus_go_mem_limit_percent must be greater than 0 and less than 100. Got %s.", tostring(local.prometheus_go_mem_limit_percent_value))
  }
}

check "grafana_auth_identity_client" {
  assert {
    condition = !local.grafana_auth_enabled || (
      contains(local.available_identity_realms, local.grafana_auth_keycloak_realm_value) &&
      trimspace(local.grafana_oidc_issuer) != "" &&
      trimspace(local.grafana_oidc_client_id) != "" &&
      trimspace(local.grafana_oidc_client_secret) != ""
    )
    error_message = format("Grafana Keycloak auth is enabled for realm %q, but identity state does not expose that realm with a confidential grafana OIDC client. Available realms: %s", local.grafana_auth_keycloak_realm_value, join(", ", local.available_identity_realms))
  }
}

check "grafana_auth_groups" {
  assert {
    condition     = !local.grafana_auth_enabled || (length(local.grafana_auth_allowed_groups) > 0 && length(local.missing_grafana_auth_group_definitions) == 0)
    error_message = format("Grafana auth groups must exist in the selected Keycloak realm. Missing logical groups: %s", join(", ", local.missing_grafana_auth_group_definitions))
  }
}

check "prometheus_auth_identity_client" {
  assert {
    condition = !local.prometheus_auth_enabled || (
      contains(local.available_identity_realms, local.prometheus_auth_keycloak_realm_value) &&
      trimspace(local.prometheus_oidc_issuer) != "" &&
      trimspace(local.prometheus_oidc_client_id) != "" &&
      trimspace(local.prometheus_oidc_client_secret) != ""
    )
    error_message = format("Prometheus Keycloak auth is enabled for realm %q, but identity state does not expose that realm with a confidential prometheus OIDC client. Available realms: %s", local.prometheus_auth_keycloak_realm_value, join(", ", local.available_identity_realms))
  }
}

check "prometheus_auth_groups" {
  assert {
    condition     = !local.prometheus_auth_enabled || (length(local.prometheus_auth_effective_allowed_groups) > 0 && length(local.missing_prometheus_auth_group_definitions) == 0)
    error_message = format("Prometheus auth groups must exist in the selected Keycloak realm. Missing logical groups: %s", join(", ", local.missing_prometheus_auth_group_definitions))
  }
}

check "otlp_public_configuration" {
  assert {
    condition = !local.otlp_public_enabled_value || (
      local.otlp_public_hostname_value != "" &&
      local.otlp_public_tls_secret_name_value != "" &&
      local.otlp_public_oidc_issuer_value != "" &&
      length(local.otlp_public_cors_allowed_origins_value) > 0 &&
      alltrue([
        for origin in local.otlp_public_cors_allowed_origins_value :
        origin == format("https://*.%s", local.domain) || (
          !strcontains(origin, "*") && can(regex("^https?://[^/]+$", origin))
        )
      ])
    )
    error_message = "Public OTLP requires a hostname, TLS secret name, Keycloak realm, and CORS origins. The only wildcard accepted is https://*.<cluster domain>; all other origins must be explicit HTTP(S) origins."
  }
}

check "ceph_prometheus_scheme" {
  assert {
    condition     = contains(["http", "https"], local.ceph_prometheus_scheme_value)
    error_message = format("ceph_external.prometheus_scheme must be \"http\" or \"https\", got %q", local.ceph_prometheus_scheme_value)
  }
}

check "monitoring_credentials" {
  assert {
    condition = (
      trimspace(local.monitoring_grafana_admin_password) != "" &&
      trimspace(local.monitoring_grafana_postgres_password) != "" &&
      trimspace(local.monitoring_prometheus_api_basic_auth_password) != "" &&
      trimspace(local.monitoring_prometheus_api_basic_auth_hash) != "" &&
      (!local.prometheus_auth_enabled || trimspace(local.monitoring_prometheus_oauth_cookie_secret) != "")
    )
    error_message = "credentials.json must define monitoring.grafana_admin_password, monitoring.grafana_postgres_password, monitoring.prometheus_api_basic_auth_password, monitoring.prometheus_api_basic_auth_hash, and monitoring.prometheus_oauth_cookie_secret when Prometheus OAuth is enabled."
  }
}

resource "kubernetes_manifest" "monitoring_namespace" {
  manifest = local.monitoring_namespace
}

resource "kubernetes_manifest" "extra_namespaces" {
  for_each = { for i, m in local.extra_namespaces : i => m }
  manifest = each.value
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }

  data = {
    "admin-user"     = local.grafana_admin_user
    "admin-password" = local.monitoring_grafana_admin_password
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "grafana_db" {
  metadata {
    name      = "grafana-db"
    namespace = "monitoring"
  }

  data = {
    username = local.grafana_db_username_value
    password = local.monitoring_grafana_postgres_password
    database = local.grafana_db_name_value
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "prometheus_api_basic_auth" {
  metadata {
    name      = local.prometheus_api_basic_auth_secret_name_value
    namespace = "monitoring"
  }

  data = {
    auth = format("%s:%s", local.prometheus_api_basic_auth_user, local.monitoring_prometheus_api_basic_auth_hash)
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "grafana_oauth" {
  count = local.grafana_auth_enabled ? 1 : 0

  metadata {
    name      = local.grafana_oauth_secret_name_value
    namespace = "monitoring"
  }

  data = {
    "client-secret" = local.grafana_oidc_client_secret
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "grafana_oauth_ca" {
  count = local.grafana_auth_ca_enabled ? 1 : 0

  metadata {
    name      = local.grafana_auth_ca_secret_name_value
    namespace = "monitoring"
  }

  data = {
    "ca.crt" = local.grafana_auth_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "prometheus_oauth" {
  count = local.prometheus_auth_enabled ? 1 : 0

  metadata {
    name      = local.prometheus_oauth_secret_name_value
    namespace = "monitoring"
  }

  data = {
    "client-secret" = local.prometheus_oidc_client_secret
    "cookie-secret" = local.monitoring_prometheus_oauth_cookie_secret
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "prometheus_oauth_ca" {
  count = local.prometheus_auth_ca_enabled ? 1 : 0

  metadata {
    name      = local.prometheus_auth_ca_secret_name_value
    namespace = "monitoring"
  }

  data = {
    "ca.crt" = local.prometheus_auth_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "otlp_public_oidc_ca" {
  count = local.otlp_public_enabled_value && local.otlp_public_oidc_ca_enabled ? 1 : 0

  metadata {
    name      = local.otlp_public_oidc_ca_secret_name
    namespace = "monitoring"
  }

  data = {
    "ca.crt" = local.otlp_public_oidc_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_manifest" "monitoring_other" {
  for_each = {
    for m in local.monitoring_other :
    format("%s/%s/%s", try(m.metadata.namespace, "cluster"), m.kind, m.metadata.name) => m
  }
  manifest = each.value

  field_manager {
    name            = "opentofu"
    force_conflicts = true
  }

  computed_fields = concat([
    "metadata.annotations",
    "metadata.annotations[\"deprecated.daemonset.template.generation\"]",
    "object.metadata.annotations",
    "object.metadata.annotations[\"deprecated.daemonset.template.generation\"]",
    "spec.template.metadata.annotations",
    "spec.template.spec.containers[0].resources.limits.cpu",
    "spec.template.spec.nodeSelector",
    ], try(each.value.kind, "") == "Deployment" ? [
    "spec.template.metadata.annotations[\"kubectl.kubernetes.io/restartedAt\"]",
    "object.spec.template.metadata.annotations",
    "object.spec.template.metadata.annotations[\"kubectl.kubernetes.io/restartedAt\"]",
  ] : [])
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
      object.metadata.annotations,
      object.spec.template.metadata.annotations,
      object.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_secret_v1.grafana_db,
    kubernetes_secret_v1.grafana_oauth,
    kubernetes_secret_v1.grafana_oauth_ca,
    kubernetes_secret_v1.prometheus_api_basic_auth,
    kubernetes_secret_v1.prometheus_oauth,
    kubernetes_secret_v1.prometheus_oauth_ca,
    kubernetes_secret_v1.otlp_public_oidc_ca,
  ]
}

resource "local_file" "monitoring_daemonsets" {
  count = length(local.monitoring_daemonsets) > 0 ? 1 : 0

  filename = "${path.module}/.generated-monitoring-daemonsets.yaml"
  content  = join("\n---\n", [for m in local.monitoring_daemonsets : yamlencode(m)])
}

resource "null_resource" "monitoring_daemonsets" {
  count = length(local.monitoring_daemonsets) > 0 ? 1 : 0

  triggers = {
    manifest_sha = sha256(local_file.monitoring_daemonsets[0].content)
  }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_file.monitoring_daemonsets[0].filename}"
  }

  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
    kubernetes_manifest.monitoring_other,
    local_file.monitoring_daemonsets,
  ]
}

resource "local_file" "monitoring_jobs" {
  count = length(local.monitoring_jobs) > 0 ? 1 : 0

  filename = "${path.module}/.generated-monitoring-jobs.yaml"
  content  = join("\n---\n", [for m in local.monitoring_jobs : yamlencode(m)])
}

resource "null_resource" "monitoring_jobs" {
  count = length(local.monitoring_jobs) > 0 ? 1 : 0

  triggers = {
    manifest_sha = sha256(local_file.monitoring_jobs[0].content)
  }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_file.monitoring_jobs[0].filename}"
  }

  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
    kubernetes_manifest.monitoring_other,
    kubernetes_secret_v1.grafana_admin,
    local_file.monitoring_jobs,
  ]

}

resource "null_resource" "cert_manager_webhook_ready" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source == "preissued" ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type = "kubernetes.io/tls"

  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
  ]
}

resource "kubernetes_manifest" "monitoring_certificates" {
  for_each = { for i, m in local.monitoring_certificates : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "monitoring_ingress" {
  for_each = { for i, m in local.monitoring_ingress : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.monitoring_other,
    kubernetes_manifest.monitoring_certificates,
    kubernetes_secret_v1.prometheus_api_basic_auth,
    kubernetes_secret_v1.preissued_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "grafana_url" {
  value = "https://${local.grafana_hostname}"
}

output "prometheus_url" {
  value = "https://${local.prometheus_hostname}"
}

output "prometheus_api_url" {
  value = "https://${local.prometheus_api_hostname_value}"
}

output "prometheus_api_basic_auth_user" {
  value = local.prometheus_api_basic_auth_user
}

output "prometheus_api_basic_auth_password" {
  value     = local.monitoring_prometheus_api_basic_auth_password
  sensitive = true
}

output "grafana_admin_user" {
  value = local.grafana_admin_user
}

output "grafana_admin_password" {
  value     = local.monitoring_grafana_admin_password
  sensitive = true
}
