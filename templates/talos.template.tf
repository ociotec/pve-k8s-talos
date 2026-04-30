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
  cluster_already_bootstrapped = fileexists("${path.module}/../kubeconfig")
}

# Generated from templates/controlplane-data.template.tf
__CONTROLPLANE_DATA__

resource "talos_machine_configuration_apply" "controlplane_config_apply" {
  for_each                    = local.controlplane_vms
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
  depends_on                  = [null_resource.all_vms_ready]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = local.worker_machine_config[each.key]
  node                        = each.value.ip
}

resource "null_resource" "controlplane_api_ready" {
  count = local.cluster_already_bootstrapped ? 0 : 1
  depends_on = [
    talos_machine_configuration_apply.controlplane_config_apply,
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
          if [ $((now-start_time)) -ge 300 ]; then
            echo "Error: Talos API on $node_ip did not leave maintenance mode within 300s." >&2
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
  depends_on           = [null_resource.controlplane_api_ready, talos_machine_configuration_apply.worker_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
}

data "talos_cluster_health" "health" {
  count                = local.cluster_already_bootstrapped ? 0 : 1
  depends_on           = [null_resource.controlplane_api_ready, talos_machine_configuration_apply.worker_config_apply]
  client_configuration = data.talos_client_configuration.talosconfig.client_configuration
  control_plane_nodes  = [for v in local.controlplane_vms : v.ip]
  worker_nodes         = [for v in local.worker_vms : v.ip]
  endpoints            = data.talos_client_configuration.talosconfig.endpoints
  # On scale-out runs, new workers can take a bit longer to finish all k8s checks
  # even though the cluster is already usable. Give the provider more time here.
  timeouts = {
    read = "30m"
  }
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  count                = local.cluster_already_bootstrapped ? 0 : 1
  depends_on           = [talos_machine_bootstrap.bootstrap, talos_machine_configuration_apply.controlplane_config_apply, talos_machine_configuration_apply.worker_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
  timeouts = {
    read = "5m"
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

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = local.cluster_already_bootstrapped ? file("${path.module}/../kubeconfig") : resource.talos_cluster_kubeconfig.kubeconfig[0].kubeconfig_raw
  sensitive = true
}
