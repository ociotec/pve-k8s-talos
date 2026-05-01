terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
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

variable "skip_identity" {
  type        = bool
  default     = false
  description = "Skip identity services."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  keycloak_enabled = trimspace(local.keycloak_hostname) != ""
  identity_resources = [
    for doc in split("\n---\n", templatefile("${path.module}/keycloak.yaml", {
      identity_namespace     = local.identity_namespace
      keycloak_hostname      = local.keycloak_hostname
      keycloak_image_tag     = local.keycloak_image_tag
      keycloak_tls_secret    = local.keycloak_tls_secret_name
      keycloak_db_name       = local.keycloak_db_name
      postgres_image_tag     = local.postgres_image_tag
      postgres_pvc_size      = local.postgres_pvc_size
      postgres_storage_class = local.postgres_storage_class
    })) :
    yamldecode(doc)
    if local.keycloak_enabled && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]

  identity_certificates = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  identity_ingress = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  identity_other = [
    for m in local.identity_resources : m
    if !contains(["Certificate", "Ingress", "Namespace"], try(m.kind, ""))
  ]
  identity_namespaces = [
    for m in local.identity_resources : m
    if try(m.kind, "") == "Namespace"
  ]
  identity_namespaces_by_id = {
    for i in range(length(local.identity_namespaces)) : tostring(i) => local.identity_namespaces[i]
  }
  identity_other_by_id = {
    for i in range(length(local.identity_other)) : tostring(i) => local.identity_other[i]
  }
  identity_certificates_by_id = {
    for i in range(length(local.identity_certificates)) : tostring(i) => local.identity_certificates[i]
  }
  identity_ingress_by_id = {
    for i in range(length(local.identity_ingress)) : tostring(i) => local.identity_ingress[i]
  }

  identity_tls_secrets = [
    for secret in local.tls_secrets : secret
    if format("%s/%s", secret.namespace, secret.secret_name) == format("%s/%s", local.identity_namespace, local.keycloak_tls_secret_name)
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.identity_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" && !var.skip_identity && local.keycloak_enabled ? [
    for secret in local.identity_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)
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
    condition     = local.tls_source != "preissued" || length(local.identity_tls_secrets) == length(local.preissued_tls_secrets_by_target)
    error_message = "tls_secrets contains duplicate namespace/secret_name pairs for identity."
  }
}

check "preissued_tls_secrets_required" {
  assert {
    condition     = local.tls_source != "preissued" || var.skip_identity || !local.keycloak_enabled || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || var.skip_identity || !local.keycloak_enabled || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued identity tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

resource "kubernetes_manifest" "identity_namespaces" {
  for_each = !var.skip_identity ? local.identity_namespaces_by_id : tomap({})
  manifest = each.value
}

resource "random_password" "postgres_password" {
  count   = !var.skip_identity && local.keycloak_enabled ? 1 : 0
  length  = local.postgres_password_length
  special = false
}

resource "random_password" "keycloak_admin_password" {
  count   = !var.skip_identity && local.keycloak_enabled ? 1 : 0
  length  = local.keycloak_admin_password_length
  special = false
}

resource "kubernetes_secret_v1" "keycloak_db" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  metadata {
    name      = "keycloak-db"
    namespace = local.identity_namespace
  }

  data = {
    username = local.keycloak_db_username
    password = random_password.postgres_password[0].result
    database = local.keycloak_db_name
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_secret_v1" "keycloak_admin" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  metadata {
    name      = "keycloak-admin"
    namespace = local.identity_namespace
  }

  data = {
    username = local.keycloak_admin_username
    password = random_password.keycloak_admin_password[0].result
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_manifest" "identity_other" {
  for_each = !var.skip_identity ? local.identity_other_by_id : tomap({})
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "spec.template.metadata.annotations",
    "spec.template.metadata.labels",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
      manifest.spec.template.metadata.annotations,
      manifest.spec.template.metadata.labels,
    ]
  }
  depends_on = [
    kubernetes_manifest.identity_namespaces,
    kubernetes_secret_v1.keycloak_db,
    kubernetes_secret_v1.keycloak_admin,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = !var.skip_identity && local.keycloak_enabled && local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source == "preissued" && !var.skip_identity && local.keycloak_enabled ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type       = "kubernetes.io/tls"
  depends_on = [kubernetes_manifest.identity_namespaces]
}

resource "kubernetes_manifest" "identity_certificates" {
  for_each = !var.skip_identity ? local.identity_certificates_by_id : tomap({})
  manifest = each.value
  depends_on = [
    kubernetes_manifest.identity_namespaces,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  count = !var.skip_identity && local.keycloak_enabled ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "identity_ingress" {
  for_each = !var.skip_identity ? local.identity_ingress_by_id : tomap({})
  manifest = each.value
  depends_on = [
    kubernetes_manifest.identity_other,
    kubernetes_manifest.identity_certificates,
    kubernetes_secret_v1.preissued_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "keycloak_enabled" {
  value = local.keycloak_enabled && !var.skip_identity
}

output "keycloak_url" {
  value = local.keycloak_enabled && !var.skip_identity ? "https://${local.keycloak_hostname}" : null
}

output "keycloak_admin_user" {
  value = local.keycloak_enabled && !var.skip_identity ? local.keycloak_admin_username : null
}

output "keycloak_admin_password" {
  value     = local.keycloak_enabled && !var.skip_identity ? random_password.keycloak_admin_password[0].result : null
  sensitive = true
}
