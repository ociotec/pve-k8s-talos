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

variable "skip_portainer" {
  type        = bool
  default     = false
  description = "Skip Portainer deployment."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  portainer_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/portainer.yaml", {
      portainer_hostname        = local.portainer_hostname
      portainer_image           = local.portainer_image_tag
      portainer_storage         = local.portainer_storage_class
      portainer_size            = local.portainer_pvc_size
      portainer_tls_secret_name = local.portainer_tls_secret_name
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]

  platform_resources = slice(local.portainer_manifests, 0, var.skip_portainer ? 0 : length(local.portainer_manifests))

  platform_certificates = [
    for m in local.platform_resources : m
    if try(m.kind, "") == "Certificate" && local.tls_source == "ca_issuer"
  ]
  platform_ingress = [
    for m in local.platform_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  platform_other = [
    for m in local.platform_resources : m
    if !contains(["Certificate", "Ingress", "Namespace"], try(m.kind, ""))
  ]
  platform_namespaces = [
    for m in local.platform_resources : m
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
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" && !var.skip_portainer ? [
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
    condition     = local.tls_source != "preissued" || var.skip_portainer || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || var.skip_portainer || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued_tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

resource "kubernetes_manifest" "platform_namespaces" {
  for_each = { for i, m in local.platform_namespaces : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "platform_other" {
  for_each = { for i, m in local.platform_other : i => m }
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
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "null_resource" "cert_manager_webhook_ready" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_secret_v1" "preissued_tls" {
  for_each = local.tls_source == "preissued" && !var.skip_portainer ? local.preissued_tls_secrets_by_target : {}

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "tls.crt" = each.value.cert_content
    "tls.key" = each.value.key_content
  }

  type       = "kubernetes.io/tls"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "kubernetes_manifest" "platform_certificates" {
  for_each = { for i, m in local.platform_certificates : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.platform_namespaces,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "platform_ingress" {
  for_each = { for i, m in local.platform_ingress : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.platform_other,
    kubernetes_manifest.platform_certificates,
    kubernetes_secret_v1.preissued_tls,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "portainer_url" {
  value = var.skip_portainer ? null : "https://${local.portainer_hostname}"
}
