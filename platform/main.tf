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

variable "skip_platform" {
  type        = bool
  default     = false
  description = "Skip platform services."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  rancher_enabled                   = trimspace(local.rancher_hostname) != ""
  rancher_hostname_value            = local.rancher_hostname
  rancher_tls_secret_name_value     = local.rancher_tls_secret_name
  rancher_replicas_value            = local.rancher_replicas
  rancher_private_ca_value          = local.rancher_private_ca
  rancher_bootstrap_length_value    = local.rancher_bootstrap_password_length
  rancher_namespace_manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "cattle-system"
    }
  }
  rancher_certificate_manifests = local.rancher_enabled && local.tls_source == "ca_issuer" ? [
    {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "rancher-ingress-cert"
        namespace = "cattle-system"
      }
      spec = {
        secretName = local.rancher_tls_secret_name_value
        issuerRef = {
          name = "root-ca"
          kind = "ClusterIssuer"
        }
        dnsNames = [
          local.rancher_hostname_value,
        ]
      }
    },
  ] : []
  rancher_namespaced_kinds = toset([
    "ConfigMap",
    "Deployment",
    "Ingress",
    "Secret",
    "Service",
    "ServiceAccount",
  ])
  rancher_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/rancher.yaml", {
      rancher_hostname = local.rancher_hostname_value
      rancher_replicas = tostring(local.rancher_replicas_value)
    })) :
    merge(
      yamldecode(doc),
      contains(local.rancher_namespaced_kinds, try(yamldecode(doc).kind, "")) ? {
        metadata = merge(
          try(yamldecode(doc).metadata, {}),
          { namespace = "cattle-system" },
        )
      } : {}
    )
    if local.rancher_enabled && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
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

  platform_resources = concat(
    slice(local.portainer_manifests, 0, var.skip_platform ? 0 : length(local.portainer_manifests)),
    [
      for m in [local.rancher_namespace_manifest] : m
      if !var.skip_platform && local.rancher_enabled
    ],
    [
      for m in local.rancher_manifests : m
      if !var.skip_platform
    ],
    [
      for m in local.rancher_certificate_manifests : m
      if !var.skip_platform
    ],
  )

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

  platform_tls_secrets = [
    for secret in local.tls_secrets : secret
    if local.rancher_enabled || format("%s/%s", secret.namespace, secret.secret_name) != format("cattle-system/%s", local.rancher_tls_secret_name_value)
  ]
  preissued_tls_secrets_by_target = {
    for secret in local.platform_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name) => merge(
      secret,
      try(local.available_certificates[secret.certificate], {}),
      {
        cert_content = try(file(local.available_certificates[secret.certificate].cert_path), "")
        key_content  = try(file(local.available_certificates[secret.certificate].key_path), "")
      }
    )
  }
  expected_preissued_tls_secret_targets = local.tls_source == "preissued" && !var.skip_platform ? [
    for target in concat(
      [for secret in local.platform_tls_secrets : format("%s/%s", secret.namespace, secret.secret_name)],
      local.rancher_enabled ? [format("cattle-system/%s", local.rancher_tls_secret_name_value)] : [],
    ) : target
  ] : []
  missing_preissued_tls_secret_targets = [
    for target in local.expected_preissued_tls_secret_targets : target
    if !contains(keys(local.preissued_tls_secrets_by_target), target)
  ]
  rancher_ca_content = local.rancher_enabled && local.rancher_private_ca_value ? try(file(local.root_ca_crt), "") : ""
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

check "preissued_tls_secrets_unique" {
  assert {
    condition     = local.tls_source != "preissued" || length(local.platform_tls_secrets) == length(local.preissued_tls_secrets_by_target)
    error_message = "tls_secrets contains duplicate namespace/secret_name pairs."
  }
}

check "preissued_tls_secrets_required" {
  assert {
    condition     = local.tls_source != "preissued" || var.skip_platform || length(local.missing_preissued_tls_secret_targets) == 0
    error_message = format("Missing preissued TLS secret definitions for: %s", join(", ", local.missing_preissued_tls_secret_targets))
  }
}

check "preissued_tls_secrets_files" {
  assert {
    condition = local.tls_source != "preissued" || var.skip_platform || alltrue([
      for secret in values(local.preissued_tls_secrets_by_target) :
      trimspace(secret.cert_content) != "" && trimspace(secret.key_content) != ""
    ])
    error_message = "Each preissued_tls_secrets entry must have readable, non-empty cert_path and key_path files."
  }
}

check "rancher_ca_file" {
  assert {
    condition     = !local.rancher_enabled || !local.rancher_private_ca_value || trimspace(local.rancher_ca_content) != ""
    error_message = "rancher_private_ca=true requires a readable, non-empty root_ca_crt file."
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
    "globalDefault",
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
  for_each = local.tls_source == "preissued" && !var.skip_platform ? local.preissued_tls_secrets_by_target : {}

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

resource "kubernetes_secret_v1" "rancher_ca" {
  count = !var.skip_platform && local.rancher_enabled && local.rancher_private_ca_value ? 1 : 0

  metadata {
    name      = "tls-ca"
    namespace = "cattle-system"
  }

  data = {
    "cacerts.pem" = local.rancher_ca_content
  }

  type       = "Opaque"
  depends_on = [kubernetes_manifest.platform_namespaces]
}

resource "random_password" "rancher_bootstrap" {
  count   = !var.skip_platform && local.rancher_enabled ? 1 : 0
  length  = local.rancher_bootstrap_length_value
  special = false
}

resource "kubernetes_secret_v1" "rancher_bootstrap" {
  count = !var.skip_platform && local.rancher_enabled ? 1 : 0

  metadata {
    name      = "bootstrap-secret"
    namespace = "cattle-system"
  }

  data = {
    bootstrapPassword = random_password.rancher_bootstrap[0].result
  }

  type       = "Opaque"
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
    kubernetes_secret_v1.rancher_bootstrap,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "rancher_enabled" {
  value = local.rancher_enabled && !var.skip_platform
}

output "portainer_url" {
  value = var.skip_platform ? null : "https://${local.portainer_hostname}"
}

output "rancher_url" {
  value = local.rancher_enabled && !var.skip_platform ? "https://${local.rancher_hostname_value}" : null
}

output "rancher_bootstrap_password" {
  value     = local.rancher_enabled && !var.skip_platform ? random_password.rancher_bootstrap[0].result : null
  sensitive = true
}
