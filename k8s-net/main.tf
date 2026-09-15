terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.104.0"
    }
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
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
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

variable "proxmox_endpoint" {
  type        = string
  default     = ""
  description = "Proxmox API endpoint used by automatic node remediation."
}

variable "proxmox_api_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Administrative Proxmox API token used only to provision the dedicated automatic-remediation credential."
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Disable TLS certificate verification for the Proxmox remediation API client."
}

variable "cluster_name" {
  type        = string
  default     = ""
  description = "Stable cluster identifier used to derive dedicated Proxmox remediation resource names."
}

variable "proxmox_pool" {
  type        = string
  default     = ""
  description = "Optional Proxmox pool that limits the dedicated remediation token; empty grants the limited role at /vms."
}

variable "vms" {
  type = map(object({
    node_name  = string
    vm_id      = number
    type       = string
    ip         = string
    ip2        = optional(string)
    vm_tags    = optional(string)
    k8s_labels = optional(map(string), {})
  }))
  default     = {}
  description = "Cluster VM inventory used to map Kubernetes worker names to execution-fencing targets."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

provider "helm" {
  kubernetes = {
    config_path = abspath("${path.module}/${var.kubeconfig_path}")
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
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
  enable_kyverno_audit_value = can(regex("(?m)^\\s*enable_kyverno_audit\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*enable_kyverno_audit\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : false
  enable_kyverno_enforce_value = can(regex("(?m)^\\s*enable_kyverno_enforce\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*enable_kyverno_enforce\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : false
  kyverno_enabled_value  = local.enable_kyverno_audit_value || local.enable_kyverno_enforce_value
  kyverno_failure_action = local.enable_kyverno_enforce_value ? "Enforce" : "Audit"
  kyverno_resources = local.enable_kyverno_enforce_value ? {
    admission_cpu_request = "500m"
    admission_memory      = "768Mi"
    reports_cpu_request   = "200m"
    reports_memory        = "384Mi"
    } : {
    admission_cpu_request = "250m"
    admission_memory      = "512Mi"
    reports_cpu_request   = "150m"
    reports_memory        = "256Mi"
  }
  node_remediation_enabled_value = can(regex("(?m)^\\s*node_remediation_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*node_remediation_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : false
  node_remediation_cluster_slug = trim(replace(lower(var.cluster_name), "/[^a-z0-9]+/", "-"), "-")
  node_remediation_name_hash    = substr(sha256(var.cluster_name), 0, 8)
  node_remediation_token_name = format(
    "node-remediation-%s-%s",
    substr(local.node_remediation_cluster_slug, 0, 14),
    local.node_remediation_name_hash,
  )
  node_remediation_role_id = format(
    "K8sNodeRemediate-%s-%s",
    substr(local.node_remediation_cluster_slug, 0, 20),
    local.node_remediation_name_hash,
  )
  node_remediation_acl_path = trimspace(var.proxmox_pool) != "" ? "/pool/${trimspace(var.proxmox_pool)}" : "/vms"
  node_remediation_image_value = can(regex("(?m)^\\s*node_remediation_image\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]) ? (
    regex("(?m)^\\s*node_remediation_image\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]
  ) : "python:3.13-alpine"
  node_remediation_replicas_value = can(regex("(?m)^\\s*node_remediation_replicas\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_replicas\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 2
  node_remediation_evaluation_interval_seconds_value = can(regex("(?m)^\\s*node_remediation_evaluation_interval_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_evaluation_interval_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 5
  node_remediation_lease_timeout_seconds_value = can(regex("(?m)^\\s*node_remediation_lease_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_lease_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 20
  node_remediation_confirmation_seconds_value = can(regex("(?m)^\\s*node_remediation_confirmation_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_confirmation_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 5
  node_remediation_execution_fence_timeout_seconds_value = can(regex("(?m)^\\s*node_remediation_execution_fence_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_execution_fence_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 45
  node_remediation_storage_fence_timeout_seconds_value = can(regex("(?m)^\\s*node_remediation_storage_fence_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_storage_fence_timeout_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 60
  node_remediation_recovery_stability_seconds_value = can(regex("(?m)^\\s*node_remediation_recovery_stability_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_recovery_stability_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 30
  node_remediation_node_cooldown_seconds_value = can(regex("(?m)^\\s*node_remediation_node_cooldown_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_node_cooldown_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 600
  node_remediation_max_concurrent_value = can(regex("(?m)^\\s*node_remediation_max_concurrent\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_max_concurrent\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 1
  node_remediation_min_ready_controlplanes_value = can(regex("(?m)^\\s*node_remediation_min_ready_controlplanes\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_min_ready_controlplanes\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 2
  node_remediation_min_node_age_seconds_value = can(regex("(?m)^\\s*node_remediation_min_node_age_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*node_remediation_min_node_age_seconds\\s*=\\s*([0-9]+)\\s*$", local.constants_source)[0])
  ) : 300
  node_remediation_cpu_request_value = can(regex("(?m)^\\s*node_remediation_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]) ? (
    regex("(?m)^\\s*node_remediation_cpu_request\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]
  ) : "25m"
  node_remediation_cpu_limit_value = can(regex("(?m)^\\s*node_remediation_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]) ? (
    regex("(?m)^\\s*node_remediation_cpu_limit\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]
  ) : "200m"
  node_remediation_memory_value = can(regex("(?m)^\\s*node_remediation_memory\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]) ? (
    regex("(?m)^\\s*node_remediation_memory\\s*=\\s*\"([^\"]+)\"\\s*$", local.constants_source)[0]
  ) : "128Mi"
  node_remediation_nodes = {
    for name, vm in var.vms : name => {
      host = vm.node_name
      vmid = vm.vm_id
      fence_cidrs = distinct(concat(
        ["${vm.ip}${strcontains(vm.ip, ":") ? "/128" : "/32"}"],
        [for address in compact([try(vm.ip2, null)]) : "${address}${strcontains(address, ":") ? "/128" : "/32"}"]
      ))
    }
    if startswith(vm.type, "worker")
  }
  node_remediation_config = {
    evaluation_interval_seconds     = local.node_remediation_evaluation_interval_seconds_value
    lease_timeout_seconds           = local.node_remediation_lease_timeout_seconds_value
    confirmation_seconds            = local.node_remediation_confirmation_seconds_value
    execution_fence_timeout_seconds = local.node_remediation_execution_fence_timeout_seconds_value
    storage_fence_timeout_seconds   = local.node_remediation_storage_fence_timeout_seconds_value
    recovery_stability_seconds      = local.node_remediation_recovery_stability_seconds_value
    node_cooldown_seconds           = local.node_remediation_node_cooldown_seconds_value
    max_concurrent_remediations     = local.node_remediation_max_concurrent_value
    minimum_ready_controlplanes     = local.node_remediation_min_ready_controlplanes_value
    minimum_node_age_seconds        = local.node_remediation_min_node_age_seconds_value
    network_fence = {
      driver           = "rook-ceph.rbd.csi.ceph.com"
      secret_name      = "rook-csi-rbd-provisioner"
      secret_namespace = "rook-ceph"
      parameters       = { clusterID = "rook-ceph" }
    }
    nodes = local.node_remediation_nodes
  }
  node_remediation_config_json = jsonencode(local.node_remediation_config)
  node_remediation_script      = file("${path.module}/node-remediation-controller.py")
  node_remediation_manifests = [
    for doc in split("\n---\n", templatefile("${path.module}/node-remediation.yaml", {
      replicas        = local.node_remediation_replicas_value
      image           = local.node_remediation_image_value
      cpu_request     = local.node_remediation_cpu_request_value
      cpu_limit       = local.node_remediation_cpu_limit_value
      memory          = local.node_remediation_memory_value
      config_checksum = sha256("${local.node_remediation_config_json}:${local.node_remediation_script}")
    })) : yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  ingress_nginx_tracing_enabled_value = can(regex("(?m)^\\s*ingress_nginx_tracing_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0]) ? (
    tobool(regex("(?m)^\\s*ingress_nginx_tracing_enabled\\s*=\\s*(true|false)\\s*$", local.constants_source)[0])
  ) : true
  ingress_nginx_tracing_sampler_ratio_value = can(regex("(?m)^\\s*ingress_nginx_tracing_sampler_ratio\\s*=\\s*([0-9.]+)\\s*$", local.constants_source)[0]) ? (
    tonumber(regex("(?m)^\\s*ingress_nginx_tracing_sampler_ratio\\s*=\\s*([0-9.]+)\\s*$", local.constants_source)[0])
  ) : 1
  cert_manager = [
    for doc in split("\n---\n", file("${path.module}/cert-manager.yaml")) :
    yamldecode(doc)
    if length(regexall("(?m)^\\s*[^#\\s]", doc)) > 0
  ]
  kyverno_policies = [
    for doc in split("\n---\n", templatefile("${path.module}/kyverno-policies.yaml", {
      failure_action = local.kyverno_failure_action
    })) : yamldecode(doc)
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
    for doc in split("\n---\n", templatefile("${path.module}/metallb-native.yaml", {
      metallb_controller_cpu_request = local.metallb_controller_cpu_request
      metallb_controller_cpu_limit   = local.metallb_controller_cpu_limit
      metallb_controller_mem_request = local.metallb_controller_mem_request
      metallb_controller_mem_limit   = local.metallb_controller_mem_limit
      metallb_speaker_cpu_request    = local.metallb_speaker_cpu_request
      metallb_speaker_cpu_limit      = local.metallb_speaker_cpu_limit
      metallb_speaker_mem_request    = local.metallb_speaker_mem_request
      metallb_speaker_mem_limit      = local.metallb_speaker_mem_limit
    })) :
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
            args = [
              "--ip-masq",
              "--kube-subnet-mgr",
              "--healthz-port=8285",
            ]
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
            readinessProbe = {
              exec = {
                command = ["/bin/sh", "-ec", "test -s /run/flannel/subnet.env"]
              }
              initialDelaySeconds = 3
              periodSeconds       = 10
              timeoutSeconds      = 1
              successThreshold    = 1
              failureThreshold    = 3
            }
            livenessProbe = {
              httpGet = {
                path   = "/healthz"
                port   = 8285
                scheme = "HTTP"
              }
              initialDelaySeconds = 10
              periodSeconds       = 10
              timeoutSeconds      = 1
              successThreshold    = 1
              failureThreshold    = 3
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
            readinessProbe = {
              httpGet = {
                path   = "/healthz"
                port   = 10256
                scheme = "HTTP"
              }
              initialDelaySeconds = 3
              periodSeconds       = 10
              timeoutSeconds      = 1
              successThreshold    = 1
              failureThreshold    = 3
            }
            livenessProbe = {
              httpGet = {
                path   = "/healthz"
                port   = 10256
                scheme = "HTTP"
              }
              initialDelaySeconds = 10
              periodSeconds       = 10
              timeoutSeconds      = 1
              successThreshold    = 1
              failureThreshold    = 3
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

check "kyverno_mode" {
  assert {
    condition     = !(local.enable_kyverno_audit_value && local.enable_kyverno_enforce_value)
    error_message = "enable_kyverno_audit and enable_kyverno_enforce are mutually exclusive."
  }
}

check "node_remediation_configuration" {
  assert {
    condition = !local.node_remediation_enabled_value || (
      var.proxmox_endpoint != "" &&
      var.proxmox_api_token != "" &&
      local.node_remediation_cluster_slug != "" &&
      length(local.node_remediation_nodes) > 0 &&
      local.node_remediation_replicas_value >= 2 &&
      local.node_remediation_evaluation_interval_seconds_value >= 2 &&
      local.node_remediation_lease_timeout_seconds_value >= 15 &&
      local.node_remediation_confirmation_seconds_value >= 5 &&
      local.node_remediation_execution_fence_timeout_seconds_value >= 15 &&
      local.node_remediation_storage_fence_timeout_seconds_value >= 30 &&
      local.node_remediation_recovery_stability_seconds_value >= 30 &&
      local.node_remediation_node_cooldown_seconds_value >= 300 &&
      local.node_remediation_max_concurrent_value >= 1 &&
      local.node_remediation_min_ready_controlplanes_value >= 1 &&
      local.node_remediation_min_node_age_seconds_value >= 60
    )
    error_message = "Automatic node remediation requires PVE credentials, at least one worker, two controller replicas, and timing values above the safety minima."
  }
}

resource "proxmox_virtual_environment_role" "node_remediation" {
  count = local.node_remediation_enabled_value ? 1 : 0

  role_id    = local.node_remediation_role_id
  privileges = ["VM.Audit", "VM.PowerMgmt"]
}

resource "proxmox_user_token" "node_remediation" {
  count = local.node_remediation_enabled_value ? 1 : 0

  user_id               = "root@pam"
  token_name            = local.node_remediation_token_name
  comment               = "Automatic worker remediation for ${var.cluster_name}; managed by pve-k8s-talos"
  privileges_separation = true
}

resource "proxmox_acl" "node_remediation" {
  count = local.node_remediation_enabled_value ? 1 : 0

  path      = local.node_remediation_acl_path
  token_id  = proxmox_user_token.node_remediation[0].id
  role_id   = proxmox_virtual_environment_role.node_remediation[0].role_id
  propagate = true
}

output "node_remediation_proxmox_token_id" {
  value       = try(proxmox_user_token.node_remediation[0].id, "")
  description = "Identifier of the dedicated privilege-separated Proxmox remediation token."
}

output "node_remediation_proxmox_role_id" {
  value       = try(proxmox_virtual_environment_role.node_remediation[0].role_id, "")
  description = "Identifier of the dedicated Proxmox remediation role."
}

output "node_remediation_proxmox_acl_path" {
  value       = local.node_remediation_enabled_value ? local.node_remediation_acl_path : ""
  description = "Proxmox ACL path assigned to the dedicated remediation token."
}

resource "kubernetes_manifest" "node_remediation_config" {
  count = local.node_remediation_enabled_value ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "node-remediation-controller"
      namespace = "kube-system"
      labels = {
        "app.kubernetes.io/name"       = "node-remediation-controller"
        "app.kubernetes.io/instance"   = "node-remediation-controller"
        "app.kubernetes.io/component"  = "controller"
        "app.kubernetes.io/part-of"    = "node-remediation"
        "app.kubernetes.io/managed-by" = "infrastructure"
        "pve-k8s-talos/section"        = "k8s-net"
      }
    }
    data = {
      "config.json"   = local.node_remediation_config_json
      "controller.py" = local.node_remediation_script
    }
  }
}

resource "kubernetes_secret_v1" "node_remediation_proxmox" {
  count = local.node_remediation_enabled_value ? 1 : 0

  metadata {
    name      = "node-remediation-proxmox"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"       = "node-remediation-controller"
      "app.kubernetes.io/instance"   = "node-remediation-controller"
      "app.kubernetes.io/component"  = "controller"
      "app.kubernetes.io/part-of"    = "node-remediation"
      "app.kubernetes.io/managed-by" = "infrastructure"
      "pve-k8s-talos/section"        = "k8s-net"
    }
  }

  data = {
    endpoint    = var.proxmox_endpoint
    "api-token" = proxmox_user_token.node_remediation[0].value
    insecure    = tostring(var.proxmox_insecure)
  }

  type = "Opaque"

  depends_on = [proxmox_acl.node_remediation]
}

resource "kubernetes_manifest" "node_remediation" {
  for_each = { for i, manifest in local.node_remediation_manifests : tostring(i) => manifest if local.node_remediation_enabled_value }
  manifest = each.value

  depends_on = [
    kubernetes_manifest.infrastructure_priority_classes,
    kubernetes_manifest.node_remediation_config,
    kubernetes_secret_v1.node_remediation_proxmox,
  ]
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

resource "helm_release" "kyverno" {
  count = local.kyverno_enabled_value ? 1 : 0

  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "oci://ghcr.io/kyverno/charts"
  chart            = "kyverno"
  version          = "3.7.0"
  wait             = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [yamlencode({
    image = {
      registry = "ghcr.io"
    }
    admissionController = {
      replicas          = 2
      priorityClassName = "infra-high"
      initContainer = {
        image = {
          registry = "ghcr.io"
        }
      }
      container = {
        image = {
          registry = "ghcr.io"
        }
        resources = {
          requests = { cpu = local.kyverno_resources.admission_cpu_request, memory = local.kyverno_resources.admission_memory }
          limits   = { cpu = "1", memory = local.kyverno_resources.admission_memory }
        }
      }
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{ matchExpressions = [{ key = "node-role.kubernetes.io/control-plane", operator = "DoesNotExist" }] }]
        }
      }
      podDisruptionBudget = { enabled = true, minAvailable = 1 }
    }
    reportsController = {
      replicas          = 1
      priorityClassName = "infra-high"
      image = {
        registry = "ghcr.io"
      }
      annotations = {
        "policy.pve-k8s-talos.io/allow-missing-probes" = "true"
        "policy.pve-k8s-talos.io/exception-reason"     = "The Kyverno reports controller does not expose supported readiness and liveness health endpoints."
      }
      resources = {
        requests = { cpu = local.kyverno_resources.reports_cpu_request, memory = local.kyverno_resources.reports_memory }
        limits   = { cpu = "500m", memory = local.kyverno_resources.reports_memory }
      }
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{ matchExpressions = [{ key = "node-role.kubernetes.io/control-plane", operator = "DoesNotExist" }] }]
        }
      }
    }
    backgroundController = { enabled = false }
    cleanupController    = { enabled = false }
  })]

  depends_on = [kubernetes_manifest.infrastructure_priority_classes]
}

resource "local_file" "kyverno_policies" {
  count    = local.kyverno_enabled_value ? 1 : 0
  filename = "${path.module}/.generated-kyverno-policies.yaml"
  content  = join("\n---\n", [for policy in local.kyverno_policies : yamlencode(policy)])
}

resource "null_resource" "kyverno_policies" {
  count = local.kyverno_enabled_value ? 1 : 0

  triggers = { manifest_sha = sha256(local_file.kyverno_policies[0].content) }

  provisioner "local-exec" {
    command = "KUBECONFIG=${abspath("${path.module}/${var.kubeconfig_path}")} kubectl apply -f ${local_file.kyverno_policies[0].filename}"
  }

  depends_on = [helm_release.kyverno, local_file.kyverno_policies]
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
