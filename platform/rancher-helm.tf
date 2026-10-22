# A mode switch is not a migration. Refuse to adopt an existing installation.
data "kubernetes_resources" "rancher_mode_guard" {
  for_each = local.rancher_enabled && !var.skip_platform ? {
    deployment = { api = "apps/v1", kind = "Deployment", namespace = "cattle-system", name = "rancher" }
    service    = { api = "v1", kind = "Service", namespace = "cattle-system", name = "rancher" }
    internal   = { api = "v1", kind = "Service", namespace = "cattle-system", name = "rancher-internal" }
    ingress    = { api = "networking.k8s.io/v1", kind = "Ingress", namespace = "cattle-system", name = "rancher" }
    account    = { api = "v1", kind = "ServiceAccount", namespace = "cattle-system", name = "rancher" }
    config     = { api = "v1", kind = "ConfigMap", namespace = "cattle-system", name = "rancher-config" }
    binding    = { api = "rbac.authorization.k8s.io/v1", kind = "ClusterRoleBinding", namespace = null, name = "rancher" }
  } : {}

  api_version    = each.value.api
  kind           = each.value.kind
  namespace      = each.value.namespace
  field_selector = "metadata.name=${each.value.name}"
}

locals {
  rancher_mode_conflicts = flatten([
    for key, result in data.kubernetes_resources.rancher_mode_guard : [
      for object in result.objects : key
      if(try(object.metadata.annotations["meta.helm.sh/release-name"], "") == "rancher" &&
        try(object.metadata.annotations["meta.helm.sh/release-namespace"], "") == "cattle-system"
      ) != (local.rancher_deployment_mode_value == "helm")
    ]
  ])
  rancher_existing_helm_deployment = anytrue([
    for object in try(data.kubernetes_resources.rancher_mode_guard["deployment"].objects, []) :
    try(object.metadata.annotations["meta.helm.sh/release-name"], "") == "rancher" &&
    try(object.metadata.annotations["meta.helm.sh/release-namespace"], "") == "cattle-system"
  ])
}

# Deleting only the old Deployment must not silently upgrade its retained data.
data "kubernetes_resources" "rancher_management_crd" {
  count          = local.rancher_helm_enabled ? 1 : 0
  api_version    = "apiextensions.k8s.io/v1"
  kind           = "CustomResourceDefinition"
  field_selector = "metadata.name=clusters.management.cattle.io"
}

resource "terraform_data" "rancher_mode_guard" {
  count = local.rancher_enabled && !var.skip_platform ? 1 : 0
  input = local.rancher_deployment_mode_value

  lifecycle {
    precondition {
      condition     = contains(["legacy", "helm"], local.rancher_deployment_mode_value)
      error_message = "rancher_deployment_mode must be legacy or helm."
    }
    precondition {
      condition     = length(local.rancher_mode_conflicts) == 0
      error_message = "Existing Rancher resources belong to another deployment mode. Complete the reviewed migration before switching modes; automatic takeover or deletion is disabled."
    }
    precondition {
      condition = !local.rancher_helm_enabled || local.rancher_existing_helm_deployment || (
        length(try(data.kubernetes_resources.rancher_management_crd[0].objects, [])) == 0
      )
      error_message = "Rancher management CRDs remain without a Helm-owned Rancher Deployment. Review legacy data cleanup or interrupted-install recovery before installing; removing the Deployment alone is not a clean replacement."
    }
  }
}

resource "helm_release" "rancher" {
  count = local.rancher_helm_enabled ? 1 : 0

  name      = "rancher"
  namespace = "cattle-system"
  # Prepared from the digest-pinned official archive; see prepare-rancher-chart.py.
  chart   = "${path.module}/.generated-rancher-chart.tgz"
  version = local.rancher_chart_version_value
  wait    = true
  timeout = 900
  atomic  = true

  # Helm must not take over legacy objects or the repository-managed secrets.
  take_ownership = false
  postrender = {
    binary_path = "${path.module}/rancher-postrender.py"
  }

  values = [yamlencode(local.rancher_helm_values)]

  depends_on = [
    terraform_data.rancher_mode_guard,
    kubernetes_manifest.platform_namespaces,
    kubernetes_manifest.platform_certificates,
    kubernetes_secret_v1.preissued_tls,
    kubernetes_secret_v1.rancher_ca,
    kubernetes_secret_v1.rancher_bootstrap,
  ]
}

locals {
  rancher_helm_values = {
    hostname          = local.rancher_hostname_value
    replicas          = local.rancher_replicas_value
    privateCA         = local.rancher_private_ca_value
    priorityClassName = "infra-observability"
    ingress = {
      ingressClassName = "nginx"
      tls = {
        source     = "secret"
        secretName = local.rancher_tls_secret_name_value
      }
    }
    resources = {
      requests = { cpu = local.rancher_cpu_request_value, memory = local.rancher_mem_request_value }
      limits   = { cpu = local.rancher_cpu_limit_value, memory = local.rancher_mem_limit_value }
    }
    extraEnv = [
      { name = "GOMEMLIMIT", value = local.rancher_go_mem_limit },
      { name = "GOMAXPROCS", value = local.rancher_go_max_procs },
      {
        name = "CATTLE_BOOTSTRAP_PASSWORD"
        valueFrom = {
          secretKeyRef = { name = "bootstrap-secret", key = "bootstrapPassword" }
        }
      },
    ]
    debug = local.rancher_debug_value
    # Supported nested-chart values, applied before its first installation.
    # With two replicas the default RollingUpdate 25% rounds maxUnavailable to 0.
    webhook = {
      replicaCount        = 2
      priorityClassName   = "infra-high"
      podDisruptionBudget = { enabled = true, minAvailable = 1 }
      resources           = jsondecode(local.rancher_managed_resource_patches["cattle-system/rancher-webhook"].patch).spec.template.spec.containers[0].resources
    }
    # Never let an uninstall/failed atomic install clean Rancher namespaces.
    postDelete = { enabled = false }
  }
}

resource "null_resource" "rancher_local_admin" {
  count = local.rancher_helm_enabled ? 1 : 0
  triggers = {
    script_sha    = filesha256("${path.module}/ensure-rancher-admin.py")
    readiness_sha = filesha256("${path.module}/rancher_readiness.py")
  }
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} python3 ${path.module}/ensure-rancher-admin.py"
  }
  depends_on = [null_resource.rancher_ready, helm_release.rancher]
}

locals {
  rancher_readiness_checks = {
    # A previous healthy one-replica release must not satisfy the HA gate.
    replicas = { "cattle-system/rancher-webhook" = 2 }
    deployments = concat(["cattle-system/rancher"], [
      for patch in values(local.rancher_managed_resource_patches) :
      "${patch.namespace}/${patch.name}" if patch.resource == "deployment"
    ])
    releases = ["cattle-system/rancher", "cattle-system/rancher-webhook",
      "cattle-fleet-system/fleet", "cattle-fleet-system/fleet-crd",
    "cattle-fleet-local-system/fleet-agent-local", "cattle-turtles-system/rancher-turtles"]
  }
}

resource "local_file" "rancher_readiness_checks" {
  count    = local.rancher_helm_enabled ? 1 : 0
  filename        = "${path.module}/.generated-rancher-readiness.json"
  content         = jsonencode(local.rancher_readiness_checks)
  file_permission = "0644"
}

resource "null_resource" "rancher_system_ready" {
  count = local.rancher_helm_enabled ? 1 : 0
  triggers = {
    script_sha = filesha256("${path.module}/rancher_readiness.py")
    values_sha = sha256(yamlencode(local.rancher_helm_values))
    checks_sha = sha256(local_file.rancher_readiness_checks[0].content)
  }
  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} python3 ${path.module}/rancher_readiness.py systems --timeout 1800 --checks-file ${local_file.rancher_readiness_checks[0].filename}"
  }
  depends_on = [null_resource.rancher_ready, null_resource.rancher_local_admin]
}
