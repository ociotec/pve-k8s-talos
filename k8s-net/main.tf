terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
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

variable "skip_ceph" {
  type        = bool
  default     = false
  description = "Skip Rook Ceph dashboard deployment."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
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
      ingress_lb_ip = local.ingress_lb_ip
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  ingress_nginx_namespace = [
    for m in local.ingress_nginx : m
    if try(m.kind, "") == "Namespace"
  ]
  ingress_nginx_other = [
    for m in local.ingress_nginx : m
    if try(m.kind, "") != "Namespace"
  ]
  portainer = [
    for doc in split("\n---\n", templatefile("${path.module}/portainer.yaml", {
      portainer_hostname = local.portainer_hostname
      portainer_image    = local.portainer_image_tag
      portainer_storage  = local.portainer_storage_class
      portainer_size     = local.portainer_pvc_size
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  rook_dashboard = [
    for doc in split("\n---\n", templatefile("${path.module}/rook-ceph-dashboard-ingress.yaml", {
      ceph_hostname = local.ceph_hostname
    })) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  portainer_namespace = [
    for m in local.portainer : m
    if try(m.kind, "") == "Namespace" && !var.skip_portainer
  ]
  portainer_other = [
    for m in local.portainer : m
    if try(m.kind, "") != "Namespace" && !var.skip_portainer
  ]

  root_ca_crt_content = try(file(local.root_ca_crt), "")
  root_ca_key_content = try(file(local.root_ca_key), "")

  root_ca_has_crt = local.root_ca_crt != "" && trimspace(local.root_ca_crt_content) != ""
  root_ca_has_key = local.root_ca_key != "" && trimspace(local.root_ca_key_content) != ""

  root_ca_use_external = local.root_ca_has_crt && local.root_ca_has_key
  root_ca_external_ok  = local.root_ca_has_crt == local.root_ca_has_key
  root_ca_cert_pem     = local.root_ca_use_external ? local.root_ca_crt_content : tls_self_signed_cert.cert_manager_ca[0].cert_pem
  root_ca_key_pem      = local.root_ca_use_external ? local.root_ca_key_content : tls_private_key.cert_manager_ca[0].private_key_pem

  cert_manager_wait_seconds = 120
  metallb_wait_seconds      = 120
}

moved {
  from = local_file.cert_manager_ca_cert[0]
  to   = local_file.cert_manager_ca_cert
}

moved {
  from = local_file.cert_manager_ca_key[0]
  to   = local_file.cert_manager_ca_key
}

check "root_ca_files" {
  assert {
    condition = local.root_ca_external_ok
    error_message = format(
      "root_ca_crt and root_ca_key must either both exist with content or both be missing/empty. root_ca_crt=%q root_ca_key=%q",
      local.root_ca_crt,
      local.root_ca_key
    )
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
  for_each   = { for i, m in local.cert_manager_other : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.cert_manager_namespace]
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
  for_each   = { for i, m in local.metallb_native_other : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.metallb_native_namespace]
}

resource "kubernetes_manifest" "metallb_pool" {
  for_each   = { for i, m in local.metallb_pool : i => m }
  manifest   = each.value
  depends_on = [null_resource.metallb_controller_ready]
}

resource "kubernetes_manifest" "ingress_nginx" {
  for_each = { for i, m in local.ingress_nginx_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.labels",
    "spec.minReadySeconds",
    "spec.template.metadata.labels",
  ]
  depends_on = [
    kubernetes_manifest.metallb_pool,
    kubernetes_manifest.ingress_nginx_namespace,
  ]
}

resource "kubernetes_manifest" "ingress_nginx_namespace" {
  for_each   = { for i, m in local.ingress_nginx_namespace : i => m }
  manifest   = each.value
}

resource "null_resource" "ingress_nginx_webhook_ready" {
  depends_on = [kubernetes_manifest.ingress_nginx]

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s && KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller --timeout=300s"
  }
}

resource "kubernetes_manifest" "portainer_namespace" {
  for_each   = { for i, m in local.portainer_namespace : i => m }
  manifest   = each.value
  depends_on = [kubernetes_manifest.ingress_nginx]
}

resource "kubernetes_manifest" "portainer" {
  for_each = { for i, m in local.portainer_other : i => m }
  manifest = each.value
  computed_fields = [
    "metadata.labels",
    "spec.externalTrafficPolicy",
    "spec.template.spec.nodeSelector",
  ]
  depends_on = [
    kubernetes_manifest.portainer_namespace,
    null_resource.ingress_nginx_webhook_ready,
    kubernetes_manifest.cert_manager_clusterissuer,
  ]
}

resource "kubernetes_manifest" "rook_dashboard" {
  for_each = {
    for i, m in local.rook_dashboard : i => m
    if !var.skip_ceph
  }
  manifest = each.value
  computed_fields = [
    "metadata.labels",
  ]
  depends_on = [
    null_resource.ingress_nginx_webhook_ready,
    kubernetes_manifest.cert_manager_clusterissuer,
  ]
}

resource "tls_private_key" "cert_manager_ca" {
  count     = local.root_ca_use_external ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "cert_manager_ca" {
  count                 = local.root_ca_use_external ? 0 : 1
  private_key_pem       = tls_private_key.cert_manager_ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = local.root_ca_validity_hours

  subject {
    common_name  = local.root_ca_common_name
    organization = local.root_ca_organization
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
  filename        = local.root_ca_crt
  content         = local.root_ca_cert_pem
  file_permission = "0644"
  lifecycle {
    prevent_destroy = true
  }
}

resource "local_file" "cert_manager_ca_key" {
  filename        = local.root_ca_key
  content         = local.root_ca_key_pem
  file_permission = "0600"
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "cert_manager_ca" {
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
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "root-ca"
    }
    spec = {
      ca = {
        secretName = kubernetes_secret_v1.cert_manager_ca.metadata[0].name
      }
    }
  }

  depends_on = [
    kubernetes_manifest.cert_manager,
    kubernetes_secret_v1.cert_manager_ca,
    null_resource.cert_manager_webhook_ready,
  ]
}

output "portainer_url" {
  description = "Portainer HTTPS URL."
  value       = var.skip_portainer ? null : "https://${local.portainer_hostname}"
}

output "rook_ceph_dashboard_url" {
  description = "Rook Ceph dashboard HTTPS URL."
  value       = "https://${local.ceph_hostname}"
}

resource "null_resource" "cert_manager_webhook_ready" {
  depends_on = [kubernetes_manifest.cert_manager]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
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

resource "null_resource" "metallb_controller_ready" {
  depends_on = [kubernetes_manifest.metallb_native]
  # Always re-run webhook readiness checks on each apply. The cluster can be recreated
  # outside this module state, so relying on null_resource state alone is not enough.
  triggers = {
    run_id = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      kubeconfig="${abspath("${path.module}/${var.kubeconfig_path}")}"

      KUBECONFIG="$kubeconfig" kubectl -n metallb-system rollout status deploy/controller --timeout=${local.metallb_wait_seconds}s
      KUBECONFIG="$kubeconfig" kubectl -n metallb-system wait --for=condition=Ready pod -l app=metallb,component=controller --timeout=${local.metallb_wait_seconds}s
      KUBECONFIG="$kubeconfig" kubectl -n metallb-system get endpoints metallb-webhook-service \
        -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q '.'

      deadline=$((SECONDS+${local.metallb_wait_seconds}))
      while true; do
        if KUBECONFIG="$kubeconfig" kubectl apply --dry-run=server -f - >/dev/null <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: webhook-ready-check
  namespace: metallb-system
spec:
  addresses:
  - ${local.metallb_pool_start}-${local.metallb_pool_end}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: webhook-ready-check
  namespace: metallb-system
spec: {}
EOF
        then
          break
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "Error: MetalLB webhook not ready after ${local.metallb_wait_seconds}s." >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}
