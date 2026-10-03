# VPA owns its CRDs through Helm. Goldilocks uses typed Kubernetes resources so
# priorities and controller health probes do not depend on chart post-renderers.
variable "vpa_goldilocks" {
  description = "Recommendation-only VPA and authenticated Goldilocks settings. Both components are enabled by default."
  type = object({
    vpa_enabled        = optional(bool, true)
    goldilocks_enabled = optional(bool, true)
    # Global discovery includes future namespaces; false uses namespace opt-in labels.
    all_namespaces          = optional(bool, true)
    hostname                = optional(string, "")
    tls_secret_name         = optional(string, "goldilocks-tls")
    keycloak_realm          = optional(string, "")
    allowed_groups          = optional(list(string), ["k8s-admins", "monitoring-view"])
    recommender_cpu_request = optional(string, "100m")
    recommender_cpu_limit   = optional(string, "500m")
    recommender_memory      = optional(string, "512Mi")
    controller_cpu_request  = optional(string, "50m")
    controller_cpu_limit    = optional(string, "200m")
    controller_memory       = optional(string, "256Mi")
    dashboard_cpu_request   = optional(string, "50m")
    dashboard_cpu_limit     = optional(string, "200m")
    dashboard_memory        = optional(string, "256Mi")
  })
  default = {}
  validation {
    condition = alltrue([for cpu in [
      var.vpa_goldilocks.recommender_cpu_request, var.vpa_goldilocks.recommender_cpu_limit,
      var.vpa_goldilocks.controller_cpu_request, var.vpa_goldilocks.controller_cpu_limit,
      var.vpa_goldilocks.dashboard_cpu_request, var.vpa_goldilocks.dashboard_cpu_limit,
      ] : can(regex("^[1-9][0-9]*m?$", cpu)) && (
      !endswith(cpu, "m") || try(tonumber(trimsuffix(cpu, "m")) % 1000 != 0, false)
    )])
    error_message = "CPU sizing must use positive whole cores or fractional millicores; write 1 instead of 1000m."
  }
  validation {
    condition = alltrue([for memory in [
      var.vpa_goldilocks.recommender_memory, var.vpa_goldilocks.controller_memory, var.vpa_goldilocks.dashboard_memory,
      ] : can(regex("^[1-9][0-9]*(Mi|Gi)$", memory)) && (
      !endswith(memory, "Mi") || try(tonumber(trimsuffix(memory, "Mi")) % 1024 != 0, false)
    )])
    error_message = "Memory sizing must use positive Mi/Gi quantities; write 1Gi instead of 1024Mi."
  }
}

locals {
  # KSM v2 no longer exposes VPA recommendations as built-in metrics.
  # Fixed, bounded labels preserve the target namespace instead of exporter identity.
  vpa_state_metrics_config = yamlencode({
    kind = "CustomResourceStateMetrics"
    spec = {
      resources = [{
        groupVersionKind = { group = "autoscaling.k8s.io", version = "v1", kind = "VerticalPodAutoscaler" }
        metricNamePrefix = "kube_verticalpodautoscaler"
        labelsFromPath = {
          namespace             = ["metadata", "namespace"]
          verticalpodautoscaler = ["metadata", "name"]
          target_api_version    = ["spec", "targetRef", "apiVersion"]
          target_kind           = ["spec", "targetRef", "kind"]
          target_name           = ["spec", "targetRef", "name"]
        }
        metrics = concat([
          {
            name = "info"
            help = "VPA inventory and configured update mode."
            each = {
              type = "Info"
              info = { labelsFromPath = { update_mode = ["spec", "updatePolicy", "updateMode"] } }
            }
          },
          {
            name      = "status_condition"
            help      = "VPA status condition; one indicates true."
            errorLogV = 5
            each = {
              type = "Gauge"
              gauge = {
                path           = ["status", "conditions"]
                labelsFromPath = { condition = ["type"] }
                valueFrom      = ["status"]
              }
            }
          },
          ], flatten([
            for bound in ["lowerBound", "target", "upperBound", "uncappedTarget"] : [
              for resource, unit in { cpu = "core", memory = "byte" } : {
                name                      = "recommendation"
                help                      = "VPA resource recommendation for a workload container."
                errorLogV                 = 5
                commonLabels              = { bound = bound, resource = resource, unit = unit }
                each = {
                  type = "Gauge"
                  gauge = {
                    path           = ["status", "recommendation", "containerRecommendations"]
                    labelsFromPath = { container = ["containerName"] }
                    valueFrom      = [bound, resource]
                  }
                }
              }
            ]
        ]))
      }]
    }
  })
  enable_vpa_value        = var.vpa_goldilocks.vpa_enabled
  enable_goldilocks_value = var.vpa_goldilocks.goldilocks_enabled

  goldilocks_hostname_value        = var.vpa_goldilocks.hostname != "" ? var.vpa_goldilocks.hostname : "goldilocks.${local.domain}"
  goldilocks_tls_secret_name_value = var.vpa_goldilocks.tls_secret_name
  goldilocks_realm_value           = var.vpa_goldilocks.keycloak_realm
  goldilocks_allowed_groups_value  = distinct(compact(var.vpa_goldilocks.allowed_groups))
  goldilocks_effective_groups = distinct(compact(concat(
    local.goldilocks_allowed_groups_value,
    flatten([for group in local.goldilocks_allowed_groups_value : [
      for ldap_group in try(local.identity_realm_groups[local.goldilocks_realm_value][group].included_ldap_groups, []) : ldap_group.group_name
    ]])
  )))
  goldilocks_oidc_issuer   = local.enable_goldilocks_value ? try(local.identity_oidc_metadata[local.goldilocks_realm_value].issuer_url, "") : ""
  goldilocks_client_id     = local.enable_goldilocks_value ? try(local.identity_oidc_metadata[local.goldilocks_realm_value].clients["goldilocks"].client_id, "") : ""
  goldilocks_client_secret = try(local.identity_oidc_client_secrets[format("%s/goldilocks", local.goldilocks_realm_value)], "")
  goldilocks_cookie_secret = try(local.monitoring_credentials.goldilocks_oauth_cookie_secret, "")
  goldilocks_ca_content    = local.enable_goldilocks_value ? try(file(local.root_ca_crt), "") : ""
  goldilocks_missing_groups = [
    for group in local.goldilocks_allowed_groups_value : group
    if !contains(keys(try(local.identity_realm_groups[local.goldilocks_realm_value], {})), group)
  ]
  goldilocks_labels = {
    "app.kubernetes.io/name"       = "goldilocks"
    "app.kubernetes.io/instance"   = "goldilocks"
    "app.kubernetes.io/part-of"    = "goldilocks"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "monitoring"
  }
  goldilocks_components = local.enable_goldilocks_value ? {
    controller = {
      priority    = "infra-high"
      path        = "/healthz"
      args        = ["controller", "-v2", "--on-by-default=${var.vpa_goldilocks.all_namespaces}", "--metrics-port=8080"]
      cpu_request = var.vpa_goldilocks.controller_cpu_request
      cpu_limit   = var.vpa_goldilocks.controller_cpu_limit
      memory      = var.vpa_goldilocks.controller_memory
      verbs       = ["get", "list", "watch"]
      vpa_verbs   = ["get", "list", "create", "delete", "update"]
    }
    dashboard = {
      priority = "infra-observability"
      path     = "/health"
      # Disable the optional external cost integration, including its signup UI.
      args        = ["dashboard", "-v2", "--on-by-default=${var.vpa_goldilocks.all_namespaces}", "--enable-cost=false"]
      cpu_request = var.vpa_goldilocks.dashboard_cpu_request
      cpu_limit   = var.vpa_goldilocks.dashboard_cpu_limit
      memory      = var.vpa_goldilocks.dashboard_memory
      verbs       = ["get", "list"]
      vpa_verbs   = ["get", "list"]
    }
  } : {}
  goldilocks_oauth_manifests = {
    for doc in split("\n---\n", templatefile("${path.module}/goldilocks-oauth2-proxy.yaml", {
      goldilocks_hostname                    = local.goldilocks_hostname_value
      goldilocks_tls_secret_name             = local.goldilocks_tls_secret_name_value
      goldilocks_oauth_secret_name           = "goldilocks-oauth"
      goldilocks_oidc_issuer                 = local.goldilocks_oidc_issuer
      goldilocks_oidc_client_id              = local.goldilocks_client_id
      goldilocks_oauth_redirect_uri          = "https://${local.goldilocks_hostname_value}/oauth2/callback"
      goldilocks_oauth2_proxy_image_tag      = "v7.15.3"
      goldilocks_oauth2_proxy_cookie_name    = "_goldilocks_oauth2_proxy"
      goldilocks_oauth2_proxy_allowed_groups = local.goldilocks_effective_groups
      goldilocks_oauth2_proxy_cpu_request    = "50m"
      goldilocks_oauth2_proxy_cpu_limit      = "200m"
      goldilocks_oauth2_proxy_mem_request    = "128Mi"
      goldilocks_oauth2_proxy_mem_limit      = "128Mi"
      goldilocks_oauth_secret_checksum       = sha256(jsonencode([local.goldilocks_client_secret, local.goldilocks_cookie_secret]))
      goldilocks_oidc_ca_checksum            = sha256(local.goldilocks_ca_content)
    })) : "${yamldecode(doc).kind}/${yamldecode(doc).metadata.name}" => yamldecode(doc)
    if local.enable_goldilocks_value && length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  }
}

resource "kubernetes_config_map_v1" "vpa_metrics" {
  count = local.enable_vpa_value ? 1 : 0
  metadata {
    name      = "kube-state-metrics-vpa"
    namespace = "monitoring"
    labels = {
      "app.kubernetes.io/name"       = "kube-state-metrics"
      "app.kubernetes.io/instance"   = "kube-state-metrics"
      "app.kubernetes.io/component"  = "metrics-config"
      "app.kubernetes.io/part-of"    = "vpa"
      "app.kubernetes.io/managed-by" = "infrastructure"
      "pve-k8s-talos/section"        = "monitoring"
    }
  }
  data = { "config.yaml" = local.vpa_state_metrics_config }
  # CRD registration must complete before KSM starts watching VPA objects.
  depends_on = [helm_release.vpa]
}

# Use preconditions, not advisory checks, to block unprotected/invalid installs.
resource "terraform_data" "vpa_goldilocks_configuration" {
  input = { vpa = local.enable_vpa_value, goldilocks = local.enable_goldilocks_value }
  lifecycle {
    precondition {
      condition     = !local.enable_goldilocks_value || local.enable_vpa_value
      error_message = "Goldilocks requires recommendation-only VPA to be enabled."
    }
    precondition {
      condition = !local.enable_goldilocks_value || (
        trimspace(local.goldilocks_hostname_value) != "" &&
        trimspace(local.goldilocks_tls_secret_name_value) != "" &&
        trimspace(local.goldilocks_realm_value) != "" &&
        length(local.goldilocks_allowed_groups_value) > 0 &&
        length(local.goldilocks_missing_groups) == 0 &&
        local.goldilocks_oidc_issuer != "" && local.goldilocks_client_id != "" &&
        local.goldilocks_client_secret != "" && local.goldilocks_cookie_secret != "" &&
        local.goldilocks_ca_content != ""
      )
      error_message = "Goldilocks requires TLS, a configured Keycloak client, existing allowed groups, CA trust and persistent OAuth secrets. Apply identity first."
    }
  }
}

resource "helm_release" "vpa" {
  count      = local.enable_vpa_value ? 1 : 0
  name       = "vpa"
  namespace  = "monitoring"
  repository = "https://charts.fairwinds.com/stable"
  chart      = "vpa"
  version    = "5.1.0"
  wait       = true
  atomic     = true
  timeout    = 600
  values = [yamlencode({
    fullnameOverride  = "vpa"
    priorityClassName = "infra-observability"
    # Preserve Helm's release ownership label while adding repository grouping.
    podLabels = {
      "app.kubernetes.io/part-of" = "vpa"
      "pve-k8s-talos/section"     = "monitoring"
    }
    updater             = { enabled = false }
    admissionController = { enabled = false }
    "metrics-server"    = { enabled = false }
    recommender = {
      enabled = true
      image   = { repository = "registry.k8s.io/autoscaling/vpa-recommender", tag = "1.7.1" }
      podLabels = {
        "app.kubernetes.io/part-of"    = "vpa"
        "app.kubernetes.io/managed-by" = "infrastructure"
        "pve-k8s-talos/section"        = "monitoring"
      }
      podAnnotations = {
        "prometheus.io/scrape" = "true"
        "prometheus.io/port"   = "8942"
        "prometheus.io/path"   = "/metrics"
      }
      resources = {
        requests = { cpu = var.vpa_goldilocks.recommender_cpu_request, memory = var.vpa_goldilocks.recommender_memory }
        limits   = { cpu = var.vpa_goldilocks.recommender_cpu_limit, memory = var.vpa_goldilocks.recommender_memory }
      }
    }
  })]
  depends_on = [kubernetes_manifest.monitoring_namespace, terraform_data.vpa_goldilocks_configuration]
}

resource "kubernetes_service_account_v1" "goldilocks" {
  for_each = local.goldilocks_components
  metadata {
    name      = "goldilocks-${each.key}"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = each.key })
  }
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

# Separate read-only dashboard permissions from controller VPA write permissions.
resource "kubernetes_cluster_role_v1" "goldilocks" {
  for_each = local.goldilocks_components
  metadata {
    name   = "goldilocks-${each.key}"
    labels = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = each.key })
  }
  rule {
    api_groups = ["apps"]
    resources  = ["*"]
    verbs      = each.value.verbs
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods"]
    verbs      = each.value.verbs
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = each.value.verbs
  }
  rule {
    api_groups = ["autoscaling.k8s.io"]
    resources  = ["verticalpodautoscalers"]
    verbs      = each.value.vpa_verbs
  }
}

resource "kubernetes_cluster_role_binding_v1" "goldilocks" {
  for_each = local.goldilocks_components
  metadata {
    name   = "goldilocks-${each.key}"
    labels = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = each.key })
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.goldilocks[each.key].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.goldilocks[each.key].metadata[0].name
    namespace = "monitoring"
  }
}

resource "kubernetes_deployment_v1" "goldilocks" {
  for_each = local.goldilocks_components
  metadata {
    name      = "goldilocks-${each.key}"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = each.key })
  }
  spec {
    replicas = 1
    selector {
      match_labels = { "app.kubernetes.io/name" = "goldilocks", "app.kubernetes.io/instance" = "goldilocks", "app.kubernetes.io/component" = each.key }
    }
    template {
      metadata {
        labels = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = each.key })
        annotations = each.key == "controller" ? {
          "prometheus.io/scrape" = "true", "prometheus.io/port" = "8080", "prometheus.io/path" = "/metrics"
        } : {}
      }
      spec {
        service_account_name = kubernetes_service_account_v1.goldilocks[each.key].metadata[0].name
        priority_class_name  = each.value.priority
        security_context {
          run_as_non_root = true
          run_as_user     = 10324
          run_as_group    = 10324
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "goldilocks"
          image             = "us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:v4.16.2"
          image_pull_policy = "Always"
          command           = ["/goldilocks"]
          args              = each.value.args
          port {
            name           = "http"
            container_port = 8080
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = each.value.cpu_request, memory = each.value.memory }
            limits   = { cpu = each.value.cpu_limit, memory = each.value.memory }
          }
          readiness_probe {
            http_get {
              path   = each.value.path
              port   = "http"
              scheme = "HTTP"
            }
            period_seconds    = 10
            timeout_seconds   = 1
            success_threshold = 1
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path   = each.value.path
              port   = "http"
              scheme = "HTTP"
            }
            period_seconds    = 30
            timeout_seconds   = 1
            success_threshold = 1
            failure_threshold = 3
          }
          startup_probe {
            http_get {
              path   = each.value.path
              port   = "http"
              scheme = "HTTP"
            }
            period_seconds    = 5
            timeout_seconds   = 1
            success_threshold = 1
            failure_threshold = 60
          }
        }
      }
    }
  }
  lifecycle {
    # Rancher owns this operational annotation, not the workload configuration.
    ignore_changes = [metadata[0].annotations["field.cattle.io/publicEndpoints"]]
  }
  depends_on = [helm_release.vpa, kubernetes_cluster_role_binding_v1.goldilocks, terraform_data.vpa_goldilocks_configuration]
}

# Global discovery defaults to covering current and future namespaces without managing labels.
# Preserve legacy opt-in labels during migration to avoid deleting existing VPAs
# while an old controller is still running. No namespace or VPA is destroyed.
removed {
  from = kubernetes_labels.goldilocks_namespace
  lifecycle {
    destroy = false
  }
}

resource "kubernetes_service_v1" "goldilocks_dashboard" {
  count = local.enable_goldilocks_value ? 1 : 0
  metadata {
    name      = "goldilocks-dashboard"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = "dashboard" })
  }
  spec {
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/name" = "goldilocks", "app.kubernetes.io/instance" = "goldilocks", "app.kubernetes.io/component" = "dashboard" }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_secret_v1" "goldilocks_oauth" {
  count = local.enable_goldilocks_value ? 1 : 0
  metadata {
    name      = "goldilocks-oauth"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = "oauth2-proxy" })
  }
  data       = { "client-secret" = local.goldilocks_client_secret, "cookie-secret" = local.goldilocks_cookie_secret }
  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace, terraform_data.vpa_goldilocks_configuration]
}

resource "kubernetes_secret_v1" "goldilocks_oidc_ca" {
  count = local.enable_goldilocks_value ? 1 : 0
  metadata {
    name      = "goldilocks-oidc-ca"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = "oauth2-proxy" })
  }
  data       = { "ca.crt" = local.goldilocks_ca_content }
  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace]
}

resource "kubernetes_manifest" "goldilocks_certificate" {
  count = local.enable_goldilocks_value && local.tls_source == "ca_issuer" ? 1 : 0
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "goldilocks-cert", namespace = "monitoring", labels = local.goldilocks_labels }
    spec = {
      secretName = local.goldilocks_tls_secret_name_value
      issuerRef  = { name = "root-ca", kind = "ClusterIssuer" }
      dnsNames   = [local.goldilocks_hostname_value]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_namespace, null_resource.cert_manager_webhook_ready]
}

resource "kubernetes_manifest" "goldilocks_oauth" {
  for_each = local.goldilocks_oauth_manifests
  manifest = each.value
  depends_on = [
    kubernetes_secret_v1.goldilocks_oauth, kubernetes_secret_v1.goldilocks_oidc_ca,
    kubernetes_secret_v1.preissued_tls, kubernetes_manifest.goldilocks_certificate,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

resource "kubernetes_ingress_v1" "goldilocks" {
  count = local.enable_goldilocks_value ? 1 : 0
  lifecycle {
    # Rancher maintains this inventory annotation; it is not platform configuration.
    ignore_changes = [metadata[0].annotations["field.cattle.io/publicEndpoints"]]
  }
  metadata {
    name      = "goldilocks"
    namespace = "monitoring"
    labels    = merge(local.goldilocks_labels, { "app.kubernetes.io/component" = "dashboard" })
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect"          = "true"
      "nginx.ingress.kubernetes.io/auth-url"              = "http://goldilocks-oauth2-proxy.monitoring.svc.cluster.local:4180/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin"           = "https://$host/oauth2/start?rd=$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-response-headers" = "X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Groups"
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = [local.goldilocks_hostname_value]
      secret_name = local.goldilocks_tls_secret_name_value
    }
    rule {
      host = local.goldilocks_hostname_value
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.goldilocks_dashboard[0].metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_manifest.goldilocks_oauth, kubernetes_deployment_v1.goldilocks,
    kubernetes_secret_v1.preissued_tls, kubernetes_manifest.goldilocks_certificate,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

output "vpa_enabled" { value = local.enable_vpa_value }
output "goldilocks_enabled" { value = local.enable_goldilocks_value }
output "goldilocks_url" { value = local.enable_goldilocks_value ? "https://${local.goldilocks_hostname_value}" : "" }
