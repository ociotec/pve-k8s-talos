terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  monitoring_namespace = yamldecode(file("${path.module}/namespace.yaml"))
  prometheus_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/prometheus.yaml", {
      storage_class            = local.storage_class
      prometheus_storage_size  = local.prometheus_storage_size
      prometheus_retention     = local.prometheus_retention
      prometheus_image_tag     = local.prometheus_image_tag
      prometheus_hostname      = local.prometheus_hostname
      prometheus_cpu_request   = local.prometheus_cpu_request
      prometheus_cpu_limit     = local.prometheus_cpu_limit
      prometheus_mem_request   = local.prometheus_mem_request
      prometheus_mem_limit     = local.prometheus_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  grafana_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/grafana.yaml", {
      storage_class       = local.storage_class
      grafana_storage_size = local.grafana_storage_size
      grafana_image_tag   = local.grafana_image_tag
      grafana_hostname    = local.grafana_hostname
      grafana_cpu_request = local.grafana_cpu_request
      grafana_cpu_limit   = local.grafana_cpu_limit
      grafana_mem_request = local.grafana_mem_request
      grafana_mem_limit   = local.grafana_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  loki_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/loki.yaml", {
      storage_class    = local.storage_class
      loki_storage_size = local.loki_storage_size
      loki_retention   = local.loki_retention
      loki_image_tag   = local.loki_image_tag
      loki_cpu_request = local.loki_cpu_request
      loki_cpu_limit   = local.loki_cpu_limit
      loki_mem_request = local.loki_mem_request
      loki_mem_limit   = local.loki_mem_limit
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  promtail_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/promtail.yaml", {
      promtail_image_tag = local.promtail_image_tag
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
      kube_state_metrics_image_tag = local.kube_state_metrics_image_tag
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
    if try(m.kind, "") == "Certificate"
  ]
  monitoring_ingress = [
    for m in local.monitoring_resources : m
    if try(m.kind, "") == "Ingress"
  ]
  monitoring_other = [
    for m in local.monitoring_resources : m
    if !contains(["Certificate", "Ingress"], try(m.kind, ""))
  ]
}

resource "kubernetes_manifest" "monitoring_namespace" {
  manifest = local.monitoring_namespace
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

resource "kubernetes_manifest" "monitoring_other" {
  for_each = { for i, m in local.monitoring_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "metadata.annotations[\"deprecated.daemonset.template.generation\"]",
    "spec.template.spec.containers[0].resources.limits.cpu",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
    ]
  }
  depends_on = [
    kubernetes_manifest.monitoring_namespace,
    kubernetes_secret_v1.grafana_admin,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s"
  }
}

resource "kubernetes_manifest" "monitoring_certificates" {
  for_each = { for i, m in local.monitoring_certificates : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.monitoring_namespace,
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
