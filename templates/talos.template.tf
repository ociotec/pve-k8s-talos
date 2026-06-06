resource "talos_machine_secrets" "machine_secrets" {
}

data "talos_client_configuration" "talosconfig" {
  cluster_name         = var.constants["talos"]["cluster_name"]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  endpoints            = [local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip]
}

locals {
  # On scale-out re-applies we already have a working cluster and persisted configs
  # under clusters/<name>/out/. Avoid rerunning bootstrap/health gates in that case.
  # The marker is written only after the Talos health check passes; kubeconfig alone
  # can exist after a failed bootstrap attempt.
  cluster_already_bootstrapped = fileexists("${path.module}/../.talos-bootstrap-complete")
  primary_controlplane_vms     = { "__CONTROLPLANE_PRIMARY__" = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"] }
  secondary_controlplane_names = sort([for k, _ in local.controlplane_vms : k if k != "__CONTROLPLANE_PRIMARY__"])
  secondary_controlplane_vms   = { for k in local.secondary_controlplane_names : k => local.controlplane_vms[k] }
}

# Generated from templates/controlplane-data.template.tf
__CONTROLPLANE_DATA__

resource "talos_machine_configuration_apply" "controlplane_primary_config_apply" {
  for_each                    = local.primary_controlplane_vms
  depends_on                  = [null_resource.all_vms_ready]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = local.controlplane_machine_config[each.key]
  node                        = each.value.ip
}

resource "talos_machine_configuration_apply" "controlplane_secondary_config_apply" {
  for_each                    = local.secondary_controlplane_vms
  depends_on                  = [null_resource.all_vms_ready]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = local.controlplane_machine_config[each.key]
  node                        = each.value.ip
}

# Generated from templates/worker-data.template.tf
__WORKER_DATA__

# Generated from templates/machine-config-locals.template.tf
__MACHINE_CONFIG_LOCALS__

resource "talos_machine_configuration_apply" "worker_config_apply" {
  for_each                    = local.worker_vms
  depends_on                  = [null_resource.controlplane_etcd_members_ready]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = local.worker_machine_config[each.key]
  node                        = each.value.ip
}

resource "null_resource" "controlplane_api_ready" {
  count = local.cluster_already_bootstrapped ? 0 : 1
  depends_on = [
    talos_machine_configuration_apply.controlplane_primary_config_apply,
    talos_machine_configuration_apply.controlplane_secondary_config_apply,
    local_file.talosconfig,
  ]

  triggers = {
    controlplane_ips = join(",", [for v in local.controlplane_vms : v.ip])
    talosconfig_sha  = sha256(local_file.talosconfig.content)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      talosconfig="${path.module}/../talosconfig"

      for node_ip in ${join(" ", [for v in local.controlplane_vms : v.ip])}; do
        start_time=$(date +%s)
        while true; do
          if talosctl --talosconfig="$talosconfig" version -n "$node_ip" >/dev/null 2>&1; then
            break
          fi

          now=$(date +%s)
          if [ $((now-start_time)) -ge 180 ]; then
            echo "Error: Talos API on $node_ip did not leave maintenance mode within 180s." >&2
            exit 1
          fi

          sleep 5
        done
      done
    EOT
  }
}

resource "talos_machine_bootstrap" "bootstrap" {
  count                = local.cluster_already_bootstrapped ? 0 : 1
  depends_on           = [null_resource.controlplane_api_ready]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
}

resource "null_resource" "cluster_health" {
  count = local.cluster_already_bootstrapped ? 0 : 1
  depends_on = [
    null_resource.controlplane_etcd_members_ready,
    null_resource.talos_nodes_discovery_rbac,
    talos_machine_configuration_apply.worker_config_apply,
  ]

  triggers = {
    controlplane_names = join(",", keys(local.controlplane_vms))
    worker_names       = join(",", keys(local.worker_vms))
    kubeconfig_sha     = sha256(local_file.kubeconfig.content)
    talosconfig_sha    = sha256(local_file.talosconfig.content)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      talosconfig="${path.module}/../talosconfig"
      kubeconfig="${path.module}/../kubeconfig"

      start_time=$(date +%s)
      while true; do
        missing=""

        for cp_ip in ${join(" ", [for v in local.controlplane_vms : v.ip])}; do
          if ! timeout 10s talosctl --talosconfig="$talosconfig" etcd status -n "$cp_ip" >/dev/null 2>&1; then
            missing="$missing etcd-status:$cp_ip"
          fi

          members="$(timeout 10s talosctl --talosconfig="$talosconfig" etcd members -n "$cp_ip" 2>/dev/null || true)"
          for node_name in ${join(" ", keys(local.controlplane_vms))}; do
            if ! printf '%s\n' "$members" | grep -q " $node_name "; then
              missing="$missing etcd-member:$cp_ip:$node_name"
            fi
          done
        done

        nodes="$(timeout 10s kubectl --kubeconfig="$kubeconfig" get nodes --no-headers 2>/dev/null || true)"
        for node_name in ${join(" ", concat(keys(local.controlplane_vms), keys(local.worker_vms)))}; do
          if ! printf '%s\n' "$nodes" | grep -q "^$node_name[[:space:]]\\+Ready[[:space:]]"; then
            missing="$missing node-ready:$node_name"
          fi
        done

        if [ -z "$missing" ]; then
          break
        fi

        now=$(date +%s)
        if [ $((now-start_time)) -ge 600 ]; then
          echo "Error: cluster did not become healthy within 600s. Missing:$missing" >&2
          for cp_ip in ${join(" ", [for v in local.controlplane_vms : v.ip])}; do
            echo "Diagnostics for control plane $cp_ip:" >&2
            timeout 10s talosctl --talosconfig="$talosconfig" service etcd -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get machinestatuses -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get timestatuses -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get members -n "$cp_ip" >&2 || true
          done
          exit 1
        fi

        sleep 5
      done
    EOT
  }
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  count                = local.cluster_already_bootstrapped ? 0 : 1
  depends_on           = [talos_machine_bootstrap.bootstrap, talos_machine_configuration_apply.controlplane_primary_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
  timeouts = {
    read = "5m"
  }
}

resource "null_resource" "controlplane_etcd_members_ready" {
  count = local.cluster_already_bootstrapped ? 0 : 1
  depends_on = [
    talos_cluster_kubeconfig.kubeconfig,
    talos_machine_configuration_apply.controlplane_primary_config_apply,
    talos_machine_configuration_apply.controlplane_secondary_config_apply,
  ]

  triggers = {
    controlplane_names = join(",", keys(local.controlplane_vms))
    talosconfig_sha    = sha256(local_file.talosconfig.content)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      talosconfig="${path.module}/../talosconfig"
      primary_ip="${local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip}"

      start_time=$(date +%s)
      while true; do
        members="$(timeout 10s talosctl --talosconfig="$talosconfig" etcd members -n "$primary_ip" 2>/dev/null || true)"
        missing=""
        for node_name in ${join(" ", keys(local.controlplane_vms))}; do
          if ! printf '%s\n' "$members" | grep -q " $node_name "; then
            missing="$missing $node_name"
          fi
        done

        if [ -z "$missing" ]; then
          break
        fi

        now=$(date +%s)
        if [ $((now-start_time)) -ge 600 ]; then
          echo "Error: etcd did not include all control planes within 600s. Missing:$missing" >&2
          for cp_ip in ${join(" ", [for v in local.controlplane_vms : v.ip])}; do
            echo "Diagnostics for control plane $cp_ip:" >&2
            timeout 10s talosctl --talosconfig="$talosconfig" service etcd -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get machinestatuses -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get timestatuses -n "$cp_ip" >&2 || true
            timeout 10s talosctl --talosconfig="$talosconfig" get members -n "$cp_ip" >&2 || true
          done
          exit 1
        fi

        sleep 5
      done
    EOT
  }
}

resource "local_file" "talosconfig" {
  content  = data.talos_client_configuration.talosconfig.talos_config
  filename = "${path.module}/../talosconfig"
}

resource "local_file" "kubeconfig" {
  depends_on = [talos_cluster_kubeconfig.kubeconfig]
  content    = local.cluster_already_bootstrapped ? file("${path.module}/../kubeconfig") : resource.talos_cluster_kubeconfig.kubeconfig[0].kubeconfig_raw
  filename   = "${path.module}/../kubeconfig"
}

resource "local_file" "talos_nodes_discovery_rbac_manifest" {
  content  = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: system:talos-nodes
      labels:
        kubernetes.io/bootstrapping: rbac-defaults
      annotations:
        rbac.authorization.kubernetes.io/autoupdate: "true"
    rules:
      - apiGroups:
          - discovery.k8s.io
        resources:
          - endpointslices
        verbs:
          - get
          - list
          - watch
      - apiGroups:
          - ""
        resources:
          - nodes
        verbs:
          - get
          - list
          - watch
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: system:talos-nodes
      labels:
        kubernetes.io/bootstrapping: rbac-defaults
      annotations:
        rbac.authorization.kubernetes.io/autoupdate: "true"
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: system:talos-nodes
    subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: Group
        name: system:nodes
  YAML
  filename = "${path.module}/talos-nodes-discovery-rbac.yaml"
}

resource "null_resource" "talos_nodes_discovery_rbac" {
  depends_on = [local_file.kubeconfig, local_file.talos_nodes_discovery_rbac_manifest]

  triggers = {
    kubeconfig_sha = sha256(local_file.kubeconfig.content)
    manifest_sha   = sha256(local_file.talos_nodes_discovery_rbac_manifest.content)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      kubeconfig="${path.module}/../kubeconfig"
      manifest="${local_file.talos_nodes_discovery_rbac_manifest.filename}"

      for attempt in $(seq 1 60); do
        if KUBECONFIG="$kubeconfig" kubectl apply --validate=false -f "$manifest"; then
          exit 0
        fi
        sleep 5
      done

      echo "Error: failed to apply Talos discovery RBAC after 60 attempts." >&2
      exit 1
    EOT
  }
}

resource "local_file" "talos_bootstrap_complete" {
  count      = local.cluster_already_bootstrapped ? 0 : 1
  depends_on = [null_resource.cluster_health]
  content    = "ok\n"
  filename   = "${path.module}/../.talos-bootstrap-complete"
}

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = local.cluster_already_bootstrapped ? file("${path.module}/../kubeconfig") : resource.talos_cluster_kubeconfig.kubeconfig[0].kubeconfig_raw
  sensitive = true
}
