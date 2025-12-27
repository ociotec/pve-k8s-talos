# Proxmox VE k8s Talos

Automatic deployment of a k8s Talos cluster on Promox VE virtual machines with OpenTofu to create VMs infra & Talos API to create k8s cluster.

## Infrastructure

### Install requirements

First install OpenTofu & `talosctl`, for MacOS:

```bash
brew install opentofu siderolabs/tap/talosctl
```

Optionally install `direnv` to auto sets the environment variables entering one directory if that directory has a file `.envrc`:

```bash
brew install direnv
```

Then install defined dependencies in `infra&/main.tf` file with:

```bash
tofu init
```

### Customize your setup

Now you need to update several files to your current needs. Samples of the files are provided for reference, just rename them removing the `.sample` from them.

- `.envrc.sample` --> `.envrc`
  - This is an optional file, only proceed with this file creation if you also installed previous optional step `direnv`.
  - Define all required PVE environment variables to allow OpenTofu to access your PVE nodes, it's prererred to use API token authentication as described at sample file.
- `vms_constants.tf.sample` --> `vms_constants.tf`
  - Talos ISO path on PVE node.
  - Network settings (except IP address that is configured later).
  - Talos version.
- `vms_list.tf.sample` --> `vms_list.tf`
  - Map of VMs on PVE with VM name as key:
    - PVE node.
    - VM ID.
    - Type of node: `controlplane` or `worker` node.
    - IP address.
- `vms_resources.tf.sample` --> `vms_resources.tf`
  - Reources for control plane & worker nodes:
    - Count of vCPUs.
    - RAM memory in MB.
    - Disk sizes in GB (several could be specified, first is used for root disk).

### Generate Talos assets

Whenever you change `vms_list.tf`, `vms_constants.tf`, or `patches/network.template.yaml`, regenerate the Talos inputs:

```bash
./scripts/gen-talos-assets.sh
```

This script:

- Renders per-VM network patches under `patches/network-*.yaml`
- Removes stale patch files for deleted VMs
- Generates `talos.tf` from several templates:
  - [`templates/talos.template.tf`](templates/talos.template.tf) main Talos template.
  - [`templates/controlplane-data.template.tf`](templates/controlplane-data.template.tf) template for Talos control plane nodes configuration data.
  - [`templates/worker-data.template.tf`](templates/worker-data.template.tf) template for Talos worker nodes configuration data.
  - [`templates/machine-config-locals.template.tf`](templates/machine-config-locals.template.tf) just create convinient local variables for easier Talos Tofu configuration steps.

### Create the infrastructre

Apply the plan:

```bash
tofu apply -auto-approve
```

To get Talos & k8s config (automatically generated on plan apply) on default paths just run:

```bash
tofu output -raw talosconfig > ~/.talos/config
tofu output -raw kubeconfig > ~/.kube/config
```

Now you can run Talos & k8s commands:

```bash
talosctl stats --nodes 192.168.1.51
kubectl get nodes
```

### Destroy the infrastructre

If you want to programmatically destroy the plan:

```bash
tofu destroy -auto-approve -refresh=false
```

## Reset all

In order to make easier the development of this repo an utility script [`scripts/reset.sh`](scripts/reset.sh) has been created to reset full infrastructure.

:warning: **Use with caution** due to the VMs cluster will be removed.

```bash
./scripts/reset.sh
```

## References

### OpenTofu

- [Installing OpenTofu via Homebrew](https://opentofu.org/docs/intro/install/homebrew/)
- [Working with OpenTofu](https://opentofu.org/docs/intro/core-workflow/)
- [`bpg/proxmox` OpenTofu provider for Proxmox VE](https://search.opentofu.org/provider/bpg/proxmox/latest)
- [`bpg/proxmox` reference for `proxmox_virtual_environment_vm` resource](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm)

### Tutorials

- [Talos cluster on Proxmox with Terraform](https://olav.ninja/talos-cluster-on-proxmox-with-terraform)
