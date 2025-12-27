locals {
  controlplane_machine_config = {
__CONTROLPLANE_LOCALS__
  }
  worker_machine_config = {
__WORKER_LOCALS__
  }
  all_machine_config = merge(local.controlplane_machine_config, local.worker_machine_config)
}
