terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.2.1"
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

variable "skip_ceph" {
  type        = bool
  default     = false
  description = "Skip Rook Ceph dashboard deployment."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  infrastructure_priority_classes = {
    infra-critical = {
      value       = 900000000
      description = "Critical repository-managed infrastructure services that should preempt normal application workloads."
    }
    infra-high = {
      value       = 800000000
      description = "High-priority repository-managed infrastructure services such as ingress, certificates, and network controllers."
    }
    infra-observability = {
      value       = 700000000
      description = "Repository-managed observability and operational UI services."
    }
  }

  constants_source = file("${path.module}/constants.tf")
  ingress_nginx_tracing_enabled_value = can(regex("(?m)^\\s*ingress_nginx_tracing_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*ingress_nginx_tracing_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : true
  ingress_nginx_tracing_sampler_ratio_value = can(regex("(?m)^\\s*ingress_nginx_tracing_sampler_ratio\\s*=\\s*([0-9.]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*ingress_nginx_tracing_sampler_ratio\\s*=\\s*([0-9.]+)\\s*$", local.constants_source)[0])
  ) : 0.10
  cert_manager = [
    for doc in split("\n---\n", file("${path.module}/cert-manager.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  cert_manager_crds = [
    for m in local.cert_manager : m
    if try(m.kind, "") == "CustomResourceDefinition"
  ]
  cert_manager_namespace = [
    for m in local.cert_manager : m
    if try(m.kind, "") == "Namespace"
  ]
  cert_manager_other = [
    for m in local.cert_manager : m
    if try(m.kind, "") != "CustomResourceDefinition" && try(m.kind, "") != "Namespace"
  ]
  metallb_native = [
    for doc in split("\n---\n", file("${path.module}/metallb-native.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  metallb_native_crds = [
    for m in local.metallb_native : m
    if try(m.kind, "") == "CustomResourceDefinition"
  ]
  metallb_native_namespace = [
    for m in local.metallb_native : m
    if try(m.kind, "") == "Namespace"
  ]
  metallb_native_other = [
    for m in local.metallb_native : m
    if try(m.kind, "") != "CustomResourceDefinition" && try(m.kind, "") != "Namespace"
  ]
  metallb_pool = [
    for doc in split("\n---\n", templatefile("${path.module}/metallb-pool.yaml", {
      metallb_pool_start = local.metallb_pool_start
      metallb_pool_end   = local.metallb_pool_end
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  ingress_nginx = [
    for doc in split("\n---\n", templatefile("${path.module}/ingress-nginx-controller.yaml", {
      ingress_lb_ip                           = local.ingress_lb_ip
      ingress_nginx_controller_cpu_request    = local.ingress_nginx_controller_cpu_request
      ingress_nginx_controller_cpu_limit      = local.ingress_nginx_controller_cpu_limit
      ingress_nginx_controller_mem_request    = local.ingress_nginx_controller_mem_request
      ingress_nginx_controller_mem_limit      = local.ingress_nginx_controller_mem_limit
      ingress_nginx_admission_job_cpu_request = local.ingress_nginx_admission_job_cpu_request
      ingress_nginx_admission_job_cpu_limit   = local.ingress_nginx_admission_job_cpu_limit
      ingress_nginx_admission_job_mem_request = local.ingress_nginx_admission_job_mem_request
      ingress_nginx_admission_job_mem_limit   = local.ingress_nginx_admission_job_mem_limit
      ingress_nginx_tracing_enabled           = local.ingress_nginx_tracing_enabled_value
      ingress_nginx_tracing_sampler_ratio     = local.ingress_nginx_tracing_sampler_ratio_value
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  ingress_nginx_namespace = [
    for m in local.ingress_nginx : m
    if try(m.kind, "") == "Namespace"
  ]
  ingress_nginx_admission_jobs = [
    for m in local.ingress_nginx : m
    if try(m.kind, "") == "Job"
  ]
  ingress_nginx_non_namespace = [
    for m in local.ingress_nginx : m
    if try(m.kind, "") != "Namespace"
  ]
  ingress_nginx_other = {
    for i, m in local.ingress_nginx_non_namespace : tostring(i) => m
    if try(m.kind, "") != "Job"
  }
  metrics_server = [
    for doc in split("\n---\n", file("${path.module}/metrics-server.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  metrics_server_other = [
    for m in local.metrics_server : m
    if try(m.kind, "") != "APIService"
  ]
  metrics_server_apiservice = [
    for m in local.metrics_server : m
    if try(m.kind, "") == "APIService"
  ]
  coredns_domain_regex         = replace(local.domain, ".", "\\.")
  coredns_corefile             = <<-EOF
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        log . {
            class error
        }
        prometheus :9153

        template IN A ${local.domain} {
            match ^(.+\.)?${local.coredns_domain_regex}\.$
            answer "{{ .Name }} 30 IN A ${local.ingress_lb_ip}"
            fallthrough
        }

        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
  EOF
  root_ca_crt_path             = local.root_ca_crt
  root_ca_key_path             = can(regex("(?m)^\\s*root_ca_key\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0]) ? regex("(?m)^\\s*root_ca_key\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0] : ""
  root_ca_crt_content          = try(file(local.root_ca_crt_path), "")
  root_ca_key_content          = try(file(local.root_ca_key_path), "")
  root_ca_common_name_value    = can(regex("(?m)^\\s*root_ca_common_name\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0]) ? regex("(?m)^\\s*root_ca_common_name\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0] : local.domain
  root_ca_organization_value   = can(regex("(?m)^\\s*root_ca_organization\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0]) ? regex("(?m)^\\s*root_ca_organization\\s*=\\s*\"([^\"]*)\"", local.constants_source)[0] : "Generated local CA"
  root_ca_validity_hours_value = can(regex("(?m)^\\s*root_ca_validity_hours\\s*=\\s*([0-9]+)", local.constants_source)[0]) ? tonumber(regex("(?m)^\\s*root_ca_validity_hours\\s*=\\s*([0-9]+)", local.constants_source)[0]) : 876000

  root_ca_has_crt = local.root_ca_crt_path != "" && trimspace(local.root_ca_crt_content) != ""
  root_ca_has_key = local.root_ca_key_path != "" && trimspace(local.root_ca_key_content) != ""

  root_ca_use_external = local.tls_source == "ca_issuer" && local.root_ca_has_crt && local.root_ca_has_key
  root_ca_external_ok = local.tls_source == "ca_issuer" ? local.root_ca_has_crt == local.root_ca_has_key : (
    local.root_ca_has_crt && !local.root_ca_has_key
  )
  root_ca_cert_pem = local.tls_source == "ca_issuer" ? (
    local.root_ca_use_external ? local.root_ca_crt_content : tls_self_signed_cert.cert_manager_ca[0].cert_pem
  ) : ""
  root_ca_key_pem = local.tls_source == "ca_issuer" ? (
    local.root_ca_use_external ? local.root_ca_key_content : tls_private_key.cert_manager_ca[0].private_key_pem
  ) : ""

  cert_manager_wait_seconds = 120
  metallb_wait_seconds      = 120

  coredns_resources_patch = jsonencode({
    spec = {
      template = {
        spec = {
          containers = [{
            name = "coredns"
            resources = {
              requests = {
                cpu    = "100m"
                memory = "70Mi"
              }
              limits = {
                cpu    = "200m"
                memory = "70Mi"
              }
            }
          }]
        }
      }
    }
  })

  kube_flannel_resources_patch = jsonencode({
    spec = {
      template = {
        spec = {
          containers = [{
            name = "kube-flannel"
            resources = {
              requests = {
                cpu    = "100m"
                memory = "50Mi"
              }
              limits = {
                cpu    = "200m"
                memory = "50Mi"
              }
            }
          }]
        }
      }
    }
  })

  kube_proxy_resources_patch = jsonencode({
    spec = {
      template = {
        spec = {
          containers = [{
            name = "kube-proxy"
            resources = {
              requests = {
                cpu    = "50m"
                memory = "64Mi"
              }
              limits = {
                cpu    = "200m"
                memory = "64Mi"
              }
            }
          }]
        }
      }
    }
  })
}

moved {
  from = local_file.cert_manager_ca_cert
  to   = local_file.cert_manager_ca_cert[0]
}

moved {
  from = local_file.cert_manager_ca_key
  to   = local_file.cert_manager_ca_key[0]
}

moved {
  from = tls_private_key.cert_manager_ca
  to   = tls_private_key.cert_manager_ca[0]
}

moved {
  from = tls_self_signed_cert.cert_manager_ca
  to   = tls_self_signed_cert.cert_manager_ca[0]
}

moved {
  from = kubernetes_secret_v1.cert_manager_ca
  to   = kubernetes_secret_v1.cert_manager_ca[0]
}

moved {
  from = kubernetes_manifest.cert_manager_clusterissuer
  to   = kubernetes_manifest.cert_manager_clusterissuer[0]
}

check "root_ca_files" {
  assert {
    condition = local.root_ca_external_ok
    error_message = format(
      local.tls_source == "ca_issuer"
      ? "For tls_source=ca_issuer, root_ca_crt and root_ca_key must either both exist with content or both be missing/empty. root_ca_crt=%q root_ca_key=%q"
      : "For tls_source=preissued, root_ca_crt must exist with content and root_ca_key must be missing/empty. root_ca_crt=%q root_ca_key=%q",
      local.root_ca_crt_path,
      local.root_ca_key_path
    )
  }
}

check "tls_source_valid" {
  assert {
    condition     = contains(["ca_issuer", "preissued"], local.tls_source)
    error_message = format("tls_source must be \"ca_issuer\" or \"preissued\", got %q", local.tls_source)
  }
}

resource "kubernetes_manifest" "infrastructure_priority_classes" {
  for_each = local.infrastructure_priority_classes

  manifest = {
    apiVersion = "scheduling.k8s.io/v1"
    kind       = "PriorityClass"
    metadata = {
      name = each.key
      labels = {
        "app.kubernetes.io/managed-by" = "infrastructure"
      }
    }
    value            = each.value.value
    preemptionPolicy = "PreemptLowerPriority"
    description      = each.value.description
  }
}

resource "kubernetes_manifest" "cert_manager_crds" {
  for_each = { for i, m in local.cert_manager_crds : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "cert_manager_namespace" {
  for_each   = { for i, m in local.cert_manager_namespace : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.cert_manager_crds]
}

resource "kubernetes_manifest" "cert_manager" {
  for_each = { for i, m in local.cert_manager_other : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.cert_manager_namespace,
    kubernetes_manifest.infrastructure_priority_classes,
  ]
}

resource "kubernetes_manifest" "metallb_native_crds" {
  for_each = { for i, m in local.metallb_native_crds : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "metallb_native_namespace" {
  for_each   = { for i, m in local.metallb_native_namespace : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.metallb_native_crds]
}

resource "kubernetes_manifest" "metallb_native" {
  for_each = { for i, m in local.metallb_native_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "metadata.annotations[\"deprecated.daemonset.template.generation\"]",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
      manifest.metadata.annotations["deprecated.daemonset.template.generation"],
    ]
  }
  field_manager {
    force_conflicts = true
  }
  depends_on = [
    kubernetes_manifest.metallb_native_namespace,
    kubernetes_manifest.infrastructure_priority_classes,
  ]
}

resource "kubernetes_manifest" "metallb_pool" {
  for_each = { for i, m in local.metallb_pool : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "ingress_nginx" {
  for_each = local.ingress_nginx_other
  manifest = each.value
  computed_fields = [
    "metadata.labels",
    "spec.minReadySeconds",
    "spec.template.metadata.annotations",
    "spec.template.metadata.labels",
  ]
  depends_on = [
    kubernetes_manifest.metallb_pool,
    kubernetes_manifest.ingress_nginx_namespace,
    kubernetes_manifest.infrastructure_priority_classes,
  ]
  field_manager {
    force_conflicts = true
  }
}

resource "kubernetes_manifest" "ingress_nginx_namespace" {
  for_each = { for i, m in local.ingress_nginx_namespace : i => m }
  manifest = each.value
}

resource "kubernetes_manifest" "metrics_server" {
  for_each = { for i, m in local.metrics_server_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.annotations",
    "spec.template.spec.containers[0].resources.limits.cpu",
    "spec.template.spec.nodeSelector",
  ]
  lifecycle {
    ignore_changes = [
      manifest.metadata.annotations,
    ]
  }
  depends_on = [kubernetes_manifest.ingress_nginx]
}

resource "kubernetes_manifest" "metrics_server_apiservice" {
  for_each = { for i, m in local.metrics_server_apiservice : i => m }
  manifest = each.value
  depends_on = [
    kubernetes_manifest.metrics_server,
    null_resource.metrics_server_ready,
  ]
}

resource "local_file" "coredns_config" {
  filename = "${path.module}/.generated-coredns.yaml"
  content = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "coredns"
      namespace = "kube-system"
    }
    data = {
      Corefile = local.coredns_corefile
    }
  })
}

resource "null_resource" "coredns_reload" {
  triggers = {
    corefile_sha = sha256(local.coredns_corefile)
  }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_file.coredns_config.filename} && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n kube-system rollout restart deploy/coredns && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n kube-system rollout status deploy/coredns --timeout=180s"
  }

  depends_on = [local_file.coredns_config]
}

resource "null_resource" "kube_system_resource_requirements" {
  triggers = {
    coredns_resources_sha      = sha256(local.coredns_resources_patch)
    kube_flannel_resources_sha = sha256(local.kube_flannel_resources_patch)
    kube_proxy_resources_sha   = sha256(local.kube_proxy_resources_patch)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubeconfig="${abspath("${path.module}/${var.kubeconfig_path}")}"

      KUBECONFIG="$kubeconfig" kubectl -n kube-system patch deployment coredns --type=strategic --patch '${local.coredns_resources_patch}'
      KUBECONFIG="$kubeconfig" kubectl -n kube-system patch daemonset kube-flannel --type=strategic --patch '${local.kube_flannel_resources_patch}'
      KUBECONFIG="$kubeconfig" kubectl -n kube-system patch daemonset kube-proxy --type=strategic --patch '${local.kube_proxy_resources_patch}'

      KUBECONFIG="$kubeconfig" kubectl -n kube-system rollout status deployment/coredns --timeout=180s
      KUBECONFIG="$kubeconfig" kubectl -n kube-system rollout status daemonset/kube-flannel --timeout=180s
      KUBECONFIG="$kubeconfig" kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=180s
    EOT
  }

  depends_on = [null_resource.coredns_reload]
}

resource "null_resource" "metrics_server_ready" {
  depends_on = [kubernetes_manifest.metrics_server]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubeconfig="${abspath("${path.module}/${var.kubeconfig_path}")}"

      KUBECONFIG="$kubeconfig" kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s
      KUBECONFIG="$kubeconfig" kubectl -n kube-system wait --for=condition=Available deploy/metrics-server --timeout=300s
    EOT
  }
}

resource "tls_private_key" "cert_manager_ca" {
  count     = local.tls_source == "ca_issuer" && !local.root_ca_use_external ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "cert_manager_ca" {
  count                 = local.tls_source == "ca_issuer" && !local.root_ca_use_external ? 1 : 0
  private_key_pem       = tls_private_key.cert_manager_ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = local.root_ca_validity_hours_value

  subject {
    common_name  = local.root_ca_common_name_value
    organization = local.root_ca_organization_value
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

resource "local_file" "cert_manager_ca_cert" {
  count           = local.tls_source == "ca_issuer" ? 1 : 0
  filename        = local.root_ca_crt_path
  content         = local.root_ca_cert_pem
  file_permission = "0644"
  lifecycle {
    prevent_destroy = true
  }
}

resource "local_file" "cert_manager_ca_key" {
  count           = local.tls_source == "ca_issuer" ? 1 : 0
  filename        = local.root_ca_key_path
  content         = local.root_ca_key_pem
  file_permission = "0600"
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "cert_manager_ca" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  metadata {
    name      = "cert-manager-root-ca"
    namespace = "cert-manager"
  }

  data = {
    "tls.crt" = local.root_ca_cert_pem
    "tls.key" = local.root_ca_key_pem
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_manifest.cert_manager_namespace]
}

resource "kubernetes_manifest" "cert_manager_clusterissuer" {
  count = local.tls_source == "ca_issuer" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "root-ca"
    }
    spec = {
      ca = {
        secretName = kubernetes_secret_v1.cert_manager_ca[0].metadata[0].name
      }
    }
  }

  depends_on = [
    kubernetes_manifest.cert_manager,
    kubernetes_secret_v1.cert_manager_ca,
    null_resource.cert_manager_webhook_ready,
  ]
}

resource "null_resource" "cert_manager_webhook_ready" {
  depends_on = [kubernetes_manifest.cert_manager]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubeconfig="${abspath("${path.module}/${var.kubeconfig_path}")}"

      KUBECONFIG="$kubeconfig" kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=${local.cert_manager_wait_seconds}s
      KUBECONFIG="$kubeconfig" kubectl -n cert-manager wait --for=condition=Available deploy/cert-manager-cainjector --timeout=${local.cert_manager_wait_seconds}s
      KUBECONFIG="$kubeconfig" kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=${local.cert_manager_wait_seconds}s
      KUBECONFIG="$kubeconfig" kubectl -n cert-manager get endpoints cert-manager-webhook \
        -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q '.'

      deadline=$((SECONDS+${local.cert_manager_wait_seconds}))
      while true; do
        if KUBECONFIG="$kubeconfig" kubectl get validatingwebhookconfiguration cert-manager-webhook \
          -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q '.'; then
          break
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "Error: cert-manager webhook caBundle not ready after ${local.cert_manager_wait_seconds}s." >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}

output "ingress_nginx_admission_jobs" {
  value = local.ingress_nginx_admission_jobs
}

output "ingress_nginx_admission_config_sha256" {
  value = sha256(jsonencode(local.ingress_nginx_admission_jobs))
}
