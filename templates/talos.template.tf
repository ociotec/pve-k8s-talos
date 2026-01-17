resource "talos_machine_secrets" "machine_secrets" {
}

data "talos_client_configuration" "talosconfig" {
  cluster_name         = var.constants["talos"]["cluster_name"]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  endpoints            = [local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip]
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

resource "talos_machine_bootstrap" "bootstrap" {
  depends_on           = [talos_machine_configuration_apply.controlplane_config_apply, talos_machine_configuration_apply.worker_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
}

data "talos_cluster_health" "health" {
  depends_on           = [talos_machine_configuration_apply.controlplane_config_apply, talos_machine_configuration_apply.worker_config_apply]
  client_configuration = data.talos_client_configuration.talosconfig.client_configuration
  control_plane_nodes  = [for v in local.controlplane_vms : v.ip]
  worker_nodes         = [for v in local.worker_vms : v.ip]
  endpoints            = data.talos_client_configuration.talosconfig.endpoints
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  depends_on           = [talos_machine_bootstrap.bootstrap, data.talos_cluster_health.health]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.controlplane_vms["__CONTROLPLANE_PRIMARY__"].ip
}

resource "local_file" "talosconfig" {
  content  = data.talos_client_configuration.talosconfig.talos_config
  filename = "${path.module}/talosconfig"
}

resource "local_file" "kubeconfig" {
  depends_on = [talos_cluster_kubeconfig.kubeconfig]
  content    = resource.talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  filename   = "${path.module}/kubeconfig"
}

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = resource.talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive = true
}
