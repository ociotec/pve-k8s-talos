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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.8.1"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

data "terraform_remote_state" "identity" {
  count = trimspace(try(local.grafana_auth_keycloak_realm, "")) != "" ? 1 : 0

  backend = "local"
  config = {
    path = abspath("${path.root}/../identity/terraform.tfstate")
  }
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  grafana_auth_keycloak_realm_value = trimspace(try(local.grafana_auth_keycloak_realm, ""))
  grafana_auth_enabled              = local.grafana_auth_keycloak_realm_value != ""
  grafana_auth_view_groups_value    = distinct(compact(try(local.grafana_auth_view_groups, [])))
  grafana_auth_edit_groups_value    = distinct(compact(try(local.grafana_auth_edit_groups, [])))
  grafana_auth_name_value           = trimspace(try(local.grafana_auth_name, "Keycloak"))
  grafana_auth_scopes_value         = trimspace(try(local.grafana_auth_scopes, "openid profile email"))
  grafana_auth_auto_login_value     = try(local.grafana_auth_auto_login, false)
  grafana_auth_allow_sign_up_value  = try(local.grafana_auth_allow_sign_up, true)
  grafana_auth_ca_secret_name_value = try(local.grafana_auth_ca_secret_name, "grafana-oauth-ca")
  grafana_oauth_secret_name_value   = "grafana-oauth"
  grafana_oauth_redirect_uri        = format("https://%s/login/generic_oauth", local.grafana_hostname)
  grafana_oauth_post_logout_uri     = format("https://%s/login", local.grafana_hostname)
  grafana_auth_ca_content           = local.grafana_auth_enabled ? try(file(local.root_ca_crt), "") : ""
  grafana_auth_ca_enabled           = trimspace(local.grafana_auth_ca_content) != ""
  identity_realm_groups = local.grafana_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_realm_groups,
    {}
  ) : {}
  identity_oidc_metadata = local.grafana_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_metadata,
    {}
  ) : {}
  identity_oidc_secrets = local.grafana_auth_enabled ? try(
    data.terraform_remote_state.identity[0].outputs.keycloak_oidc_client_secrets,
    {}
  ) : {}
  grafana_oidc_issuer = local.grafana_auth_enabled ? try(
    local.identity_oidc_metadata[local.grafana_auth_keycloak_realm_value].issuer_url,
    ""
  ) : ""
  grafana_oidc_client_id = local.grafana_auth_enabled ? try(
    local.identity_oidc_metadata[local.grafana_auth_keycloak_realm_value].clients["grafana"].client_id,
    ""
  ) : ""
  grafana_oidc_client_secret = local.grafana_auth_enabled ? try(
    local.identity_oidc_secrets[local.grafana_auth_keycloak_realm_value]["grafana"],
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
  monitoring_namespace = yamldecode(file("${path.module}/namespace.yaml"))
  prometheus_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/prometheus.yaml", {
      storage_class              = local.storage_class
      prometheus_storage_size    = local.prometheus_storage_size
      prometheus_retention       = local.prometheus_retention
      prometheus_image_tag       = local.prometheus_image_tag
      prometheus_hostname        = local.prometheus_hostname
      prometheus_cpu_request     = local.prometheus_cpu_request
      prometheus_cpu_limit       = local.prometheus_cpu_limit
      prometheus_mem_request     = local.prometheus_mem_request
      prometheus_mem_limit       = local.prometheus_mem_limit
      prometheus_tls_secret_name = local.prometheus_tls_secret_name
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  grafana_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/grafana.yaml", {
      storage_class                      = local.storage_class
      grafana_storage_size               = local.grafana_storage_size
      grafana_image_tag                  = local.grafana_image_tag
      grafana_hostname                   = local.grafana_hostname
      grafana_cpu_request                = local.grafana_cpu_request
      grafana_cpu_limit                  = local.grafana_cpu_limit
      grafana_mem_request                = local.grafana_mem_request
      grafana_mem_limit                  = local.grafana_mem_limit
      grafana_tls_secret_name            = local.grafana_tls_secret_name
      grafana_auth_enabled               = local.grafana_auth_enabled
      grafana_auth_ca_enabled            = local.grafana_auth_ca_enabled
      grafana_auth_ca_secret_name        = local.grafana_auth_ca_secret_name_value
      grafana_oauth_secret_name          = local.grafana_oauth_secret_name_value
      grafana_auth_name                  = local.grafana_auth_name_value
      grafana_auth_scopes                = local.grafana_auth_scopes_value
      grafana_auth_auto_login            = tostring(local.grafana_auth_auto_login_value)
      grafana_auth_allow_sign_up         = tostring(local.grafana_auth_allow_sign_up_value)
      grafana_auth_allowed_groups        = join(",", local.grafana_auth_allowed_groups)
      grafana_auth_role_attribute_path   = local.grafana_auth_role_attribute_path
      grafana_oidc_client_id             = local.grafana_oidc_client_id
      grafana_oidc_auth_url              = local.grafana_oidc_auth_url
      grafana_oidc_token_url             = local.grafana_oidc_token_url
      grafana_oidc_api_url               = local.grafana_oidc_api_url
      grafana_oidc_jwk_set_url           = local.grafana_oidc_jwk_set_url
      grafana_oauth_signout_redirect_url = local.grafana_oauth_signout_redirect_url
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  loki_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/loki.yaml", {
      storage_class     = local.storage_class
      loki_storage_size = local.loki_storage_size
      loki_retention    = local.loki_retention
      loki_image_tag    = local.loki_image_tag
      loki_cpu_request  = local.loki_cpu_request
      loki_cpu_limit    = local.loki_cpu_limit
      loki_mem_request  = local.loki_mem_request
      loki_mem_limit    = local.loki_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
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

  monitoring_resources = concat(
    local.prometheus_manifests,
    local.grafana_manifests,
    local.loki_manifests,
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
          "provider.yaml" = file("${path.module}/grafana/grafana.yaml")
        }
      },
      {
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = "grafana-dashboards"
          namespace = "monitoring"
        }
        data = { for filename in fileset("${path.module}/grafana/dashboards", "*.json") :
          filename => file("${path.module}/grafana/dashboards/${filename}")
        }
      },
    ],
    local.kube_state_metrics_manifests
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
    if !contains(["Certificate", "Ingress", "Namespace"], try(m.kind, ""))
  ]
  extra_namespaces = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Namespace"
  ]

  preissued_tls_secrets_by_target = {
    for secret in local.tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" ? [
    for secret in local.tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)
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
    condition     = local.tls_source != "preissued" || length(local.tls_secrets) == length(local.preissued_tls_secrets_by_target)
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

check "grafana_auth_identity_client" {
  assert {
    condition = !local.grafana_auth_enabled || (
      trimspace(local.grafana_oidc_issuer) != "" &&
      trimspace(local.grafana_oidc_client_id) != "" &&
      trimspace(local.grafana_oidc_client_secret) != ""
    )
    error_message = format("Grafana Keycloak auth is enabled for realm %q, but identity state does not expose a confidential grafana OIDC client.", local.grafana_auth_keycloak_realm_value)
  }
}

check "grafana_auth_groups" {
  assert {
    condition     = !local.grafana_auth_enabled || (length(local.grafana_auth_allowed_groups) > 0 && length(local.missing_grafana_auth_group_definitions) == 0)
    error_message = format("Grafana auth groups must exist in the selected Keycloak realm. Missing logical groups: %s", join(", ", local.missing_grafana_auth_group_definitions))
  }
}

resource "kubernetes_manifest" "monitoring_namespace" {
  manifest = local.monitoring_namespace
}

resource "kubernetes_manifest" "extra_namespaces" {
  for_each = { for i, m in local.extra_namespaces : i => m }
  manifest = each.value
}

resource "random_password" "grafana_admin" {
  length  = local.grafana_admin_password_length
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }

  data = {
    "admin-user"     = local.grafana_admin_user
    "admin-password" = random_password.grafana_admin.result
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

resource "kubernetes_manifest" "monitoring_other" {
  for_each = { for i, m in local.monitoring_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "metadata.annotations[\"deprecated.daemonset.template.generation\"]",
    "spec.template.spec.containers[0].resources.limits.cpu",
    "spec.template.spec.nodeSelector",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
    ]
  }
  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_manifest.extra_namespaces,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_secret_v1.grafana_oauth,
    kubernetes_secret_v1.grafana_oauth_ca,
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

output "grafana_admin_user" {
  value = local.grafana_admin_user
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}
