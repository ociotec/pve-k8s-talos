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
tofu init -upgrade
```

### Customize your setup

Now you need to update several files to your current needs. Samples of the files are provided for reference, just rename them removing the `.sample` from them.

- `.envrc.sample` --> `.envrc`
  - This is an optional file, only proceed with this file creation if you also installed previous optional step `direnv`.
  - Define all required PVE environment variables to allow OpenTofu to access your PVE nodes, it's prererred to use API token authentication as described at sample file.
- `vms_constants.tf.sample` --> `vms_constants.tf`
  - Talos ISO path on PVE node.
  - Optional datastore ID for VM disks and cloud-init (defaults to `local-lvm`).
  - Proxmox pool name for VM placement (leave empty to disable).
  - `vm.disk_by_id_prefix` to build stable `/dev/disk/by-id` device names.
  - Optional `vm.tags` list (comma-separated) to append extra VM tags.
  - Network settings (except IP address that is configured later).
  - Proxmox bridge device name for all VMs (defaults to `vmbr0`).
  - DNS servers (comma-separated list, at least one required).
  - Optional VLAN tag for all VMs (leave empty to disable).
  - Optional NTP servers (comma-separated list, leave empty to disable).
  - Talos version and factory image ID (used to render `patches/qemu.yaml`).
  - Optional global `constants["k8s"]["labels"]` map applied to all k8s nodes (lowest precedence).
- `vms_list.tf.sample` --> `vms_list.tf`
  - Map of VMs on PVE with VM name as key:
    - PVE node.
    - VM ID.
    - Resource type key (must exist in `vms_resources.tf`).
    - IP address.
    - Optional `k8s_labels` map per VM (highest precedence).
- `vms_resources.tf.sample` --> `vms_resources.tf`
  - Resources per node type referenced by `vms_list.tf`:
    - Count of vCPUs.
    - RAM memory in MB.
    - `k8s_node` role: `controlplane` or `worker`.
    - Optional `k8s_labels` map per resource type (middle precedence).
    - Disks in GB with optional Talos mount points (first disk is used as root).
    - Mount points must live under `/var` (for example `/var/mnt/kafka` or `/var/lib/kafka`).
- `k8s-net/constants.tf.sample` --> `k8s-net/constants.tf`
  - Domain, CA organization, MetalLB pool range, and ingress fixed IP.
- `root_ca_crt` and `root_ca_key` paths. A new Root CA is generated only when either file is missing or empty.
- `monitoring/constants.tf.sample` --> `monitoring/constants.tf`
  - Domain, storage class, sizes, retention, and image versions for Prometheus, Loki, and Grafana.

Shortcut: for a one-command install, jump to [Easy deployment](#easy-deployment) to run the helper script; or continue reading for the detailed, step-by-step walkthrough below.

### Generate Talos assets

Whenever you change `vms_list.tf`, `vms_constants.tf`, or `patches/machine.template.yaml`, regenerate the Talos inputs:

```bash
./scripts/gen-talos-assets.sh
```

This script:

- Renders per-VM machine patches under `patches/machine-*.yaml`
- Merges node labels with precedence: `vms_constants.tf` (`constants["k8s"]["labels"]`) < `vms_resources.tf` (`k8s_labels`) < `vms_list.tf` (`k8s_labels`)
- Removes stale patch files for deleted VMs
- Generates `talos.tf` from several templates:
  - [`templates/talos.template.tf`](templates/talos.template.tf) main Talos template.
  - [`templates/controlplane-data.template.tf`](templates/controlplane-data.template.tf) template for Talos control plane nodes configuration data.
  - [`templates/worker-data.template.tf`](templates/worker-data.template.tf) template for Talos worker nodes configuration data.
  - [`templates/machine-config-locals.template.tf`](templates/machine-config-locals.template.tf) just create convinient local variables for easier Talos Tofu configuration steps.

### Disk by-id prefix

Talos uses `/dev/disk/by-id/${disk_by_id_prefix}N` to map each disk by its index.
With Proxmox, the `by-id` names typically look like `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`.

To confirm the correct prefix, run on any worker once Talos is up:

```bash
talosctl -n <worker-ip> ls /dev/disk/by-id
```

You should see entries like:

```bash
scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
```

Set `vm.disk_by_id_prefix` to the part before the index (`scsi-0QEMU_QEMU_HARDDISK_drive-scsi` in this example).

### Create the infrastructre

The easiest way is to use the provided deployment script:

```bash
./scripts/deploy.sh
```

Alternatively, you can apply the plan manually:

```bash
tofu apply -auto-approve
```

The deployment script automatically generates `talosconfig` and `kubeconfig` files in the project directory.

**Configuring your environment for future sessions:**

To use the cluster with `talosctl` and `kubectl` in new shell sessions, you have several options:

**Option 1: Set variables in your shell profile (recommended for one-time setup)**

Add these exports to your shell profile (`.bashrc`, `.zshrc`, etc.):

```bash
export TALOSCONFIG="/path/to/pve-k8s-talos/talosconfig"
export KUBECONFIG="/path/to/pve-k8s-talos/kubeconfig"
```

Or set them for each session:

```bash
export TALOSCONFIG="$(pwd)/talosconfig"
export KUBECONFIG="$(pwd)/kubeconfig"
```

**Option 2: With direnv (automatic, recommended if you have direnv)**

If you have direnv installed, add these lines to your `.envrc` file in the project directory:

```bash
export TALOSCONFIG="$(pwd)/talosconfig"
export KUBECONFIG="$(pwd)/kubeconfig"
```

Then run:

```bash
direnv allow
```

If direnv says `.envrc is blocked`, simply run `direnv allow` to approve it.

**Using the cluster:**

```bash
talosctl stats --nodes <node-ip>
kubectl get nodes
```

### Rook Ceph

Rook is split into several plan applies to avoid the CRD plan-time limitation.

#### CRDs + common + operator

First, init & apply CRDs + common + operator from the rook/01 module:

```bash
tofu -chdir=rook/01-crds-common-operator init
tofu -chdir=rook/01-crds-common-operator apply -auto-approve
```

Wait till operator is running in ready state:

```bash
kubectl get pods -n rook-ceph -w
# Something similar to this should be displayed
NAME                                 READY   STATUS              RESTARTS   AGE
rook-ceph-operator-f7867cb4b-j9qc4                        1/1     Running     0               30m
```

#### Operator creates the cluster

Then init & apply the cluster CR in the separate module:

```bash
tofu -chdir=rook/02-cluster init
tofu -chdir=rook/02-cluster apply -auto-approve
```

Wait till operator is running in ready state:

```bash
kubectl get pods -n rook-ceph -w
# Something similar to this should be displayed
NAME                                                      READY   STATUS      RESTARTS        AGE
csi-cephfsplugin-bgc24                                    3/3     Running     1 (10m ago)     10m
csi-cephfsplugin-dk746                                    3/3     Running     1 (10m ago)     10m
csi-cephfsplugin-fvbpb                                    3/3     Running     1 (10m ago)     10m
csi-cephfsplugin-provisioner-76f4969f64-dksnv             6/6     Running     4 (9m26s ago)   10m
csi-cephfsplugin-provisioner-76f4969f64-td64m             6/6     Running     1 (10m ago)     10m
csi-rbdplugin-4zv88                                       3/3     Running     1 (10m ago)     10m
csi-rbdplugin-provisioner-7fcf98fc66-cbl6w                6/6     Running     1 (10m ago)     10m
csi-rbdplugin-provisioner-7fcf98fc66-p4bbn                6/6     Running     4 (9m20s ago)   10m
csi-rbdplugin-slw2x                                       3/3     Running     1 (10m ago)     10m
csi-rbdplugin-z96gx                                       3/3     Running     1 (10m ago)     10m
rook-ceph-crashcollector-talos-g0a-1fy-6c4d7765b9-wgqw7   1/1     Running     0               9m23s
rook-ceph-crashcollector-talos-lhn-rw4-6765469886-px7n8   1/1     Running     0               8m29s
rook-ceph-crashcollector-talos-t5y-zub-6ff5989786-rw7jm   1/1     Running     0               8m30s
rook-ceph-exporter-talos-g0a-1fy-85f85dbd97-7cgjj         1/1     Running     0               9m23s
rook-ceph-exporter-talos-lhn-rw4-7c7fff48bb-dqwv6         1/1     Running     0               8m26s
rook-ceph-exporter-talos-t5y-zub-84fbcc7594-f7m2t         1/1     Running     0               8m27s
rook-ceph-mgr-a-57f77966b9-7xjk7                          3/3     Running     0               9m20s
rook-ceph-mgr-b-67bd5d7648-j67zm                          3/3     Running     0               9m19s
rook-ceph-mon-a-5f4b4f54db-b9nrz                          2/2     Running     0               10m
rook-ceph-mon-b-9455f46b6-9lbbd                           2/2     Running     0               10m
rook-ceph-mon-c-64d8f5665d-8wfxk                          2/2     Running     0               9m47s
rook-ceph-operator-f7867cb4b-j9qc4                        1/1     Running     0               31m
rook-ceph-osd-0-f96ff4b47-dgsdm                           2/2     Running     0               7m21s
rook-ceph-osd-1-5bf66dfdc8-8zg8n                          2/2     Running     0               6m57s
rook-ceph-osd-2-7dd7c8cf97-gmfm5                          2/2     Running     0               6m30s
rook-ceph-osd-prepare-talos-g0a-1fy-vjq5l                 0/1     Completed   0               7m31s
rook-ceph-osd-prepare-talos-lhn-rw4-mvqtz                 0/1     Completed   0               7m28s
rook-ceph-osd-prepare-talos-t5y-zub-wsg42                 0/1     Completed   0               7m25s
```

#### Ceph dashboard

In order to visualize Ceph web dashboard, init & apply this separate module:

```bash
tofu -chdir=rook/03-dashboard init
tofu -chdir=rook/03-dashboard apply -auto-approve
```

A node port service is created to access the web dashboard, to know which TCP port is used, just list the service:

```bash
kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard-external-https
# Something similar to this should be displayed
NAME                                     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
rook-ceph-mgr-dashboard-external-https   NodePort   10.96.145.137   <none>        8443:32390/TCP   88s
# The port in this k8s cluster was 32390
```

Default `admin` user password is generated and created as a secret, to display it just run:

```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo
```

#### k8s CSI creation

In order to install k8s CSI providers based on:

- CephFS: Ceph File System - file based PVCs for multiple pod access.
- RBD: RADOS Block Device - block PVCs for only one pod access.

Init & apply this separate module:

```bash
tofu -chdir=rook/04-csi init
tofu -chdir=rook/04-csi apply -auto-approve
```

CSIs are created for all types and for erasure coded (EC) and replica modes:

```bash
kubectl -n rook-ceph get storageclasses.storage.k8s.io
# Something similar to this should be displayed
NAME                      PROVISIONER                     RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
rook-ceph-block-ec        rook-ceph.rbd.csi.ceph.com      Delete          Immediate           true                   9s
rook-ceph-block-replica   rook-ceph.rbd.csi.ceph.com      Delete          Immediate           true                   9s
rook-cephfs-ec            rook-ceph.cephfs.csi.ceph.com   Delete          Immediate           true                   10m
rook-cephfs-replica       rook-ceph.cephfs.csi.ceph.com   Delete          Immediate           true                   10m
```

### MetalLB, NGINX ingress controller & certificate manager

Define your constants in `k8s-net/constants.tf`: domain, CA organization, MetalLB pool range, and the fixed ingress IP.
The MetalLB pool and ingress service are rendered from templates using those values.
Do not apply `k8s-net/metallb-pool.yaml` or `k8s-net/ingress-nginx-controller.yaml` directly; OpenTofu renders them with your constants.

To deploy these resources run the following command:

```bash
tofu -chdir=k8s-net init
tofu -chdir=k8s-net apply -auto-approve
```

#### Install the Root CA locally

Install the generated Root CA so your browser and curl trust the `portainer.home.arpa` certificate (replace the domain if you changed it in `k8s-net/constants.tf`):

macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain k8s-net/certs/home.arpa.pem
```

Linux (Debian/Ubuntu):

```bash
sudo cp k8s-net/certs/home.arpa.pem /usr/local/share/ca-certificates/home.arpa.crt
sudo update-ca-certificates
```

Linux (RHEL/CentOS/Fedora):

```bash
sudo cp k8s-net/certs/home.arpa.pem /etc/pki/ca-trust/source/anchors/home.arpa.crt
sudo update-ca-trust
```

Windows (PowerShell, admin):

```powershell
Import-Certificate -FilePath "C:\\path\\to\\certs\\home.arpa.pem" -CertStoreLocation Cert:\\LocalMachine\\Root
```

#### Local install of root CA and /etc/hosts

Use `scripts/update-local.sh` to install the root CA and manage `/etc/hosts` entries based on `k8s-net/constants.tf` and `monitoring/constants.tf`. The script does not call `sudo`, so run it with `sudo` when it needs to edit system files.

```bash
sudo ./scripts/update-local.sh --root-ca
sudo ./scripts/update-local.sh --etc-hosts
# Or call with -a/--all to do all actions
sudo ./scripts/update-local.sh --all
```

To undo those changes, just run:

```bash
sudo ./scripts/update-local.sh --del-etc-hosts
```

#### Portainer

Portainer is installed by OpenTofu as part of `k8s-net`. Access it at (replace the domain if you changed it in `k8s-net/constants.tf`):

```text
https://portainer.home.arpa
```

If you don't have internal DNS, add an `/etc/hosts` entry using `ingress_lb_ip` from `k8s-net/constants.tf`:

```bash
192.168.1.70 portainer.home.arpa
```

#### Rook Ceph dashboard

The Rook Ceph dashboard is exposed at (replace the domain if you changed it in `k8s-net/constants.tf`):

```text
https://ceph.home.arpa
```

If you don't have internal DNS, add an `/etc/hosts` entry using `ingress_lb_ip` from `k8s-net/constants.tf`:

```bash
192.168.1.70 ceph.home.arpa
```

### Monitoring (Prometheus, Loki, Grafana)

Define your constants in `monitoring/constants.tf`: domain, storage class, PVC sizes, retention settings, and image versions.
This stack also includes kube-state-metrics (requests/limits) and kubelet cAdvisor scrape for CPU/RAM usage.
The manifests are rendered from templates using those values.
Use the same domain as `k8s-net/constants.tf` so TLS and DNS align.

To deploy the monitoring stack:

```bash
tofu -chdir=monitoring init
tofu -chdir=monitoring apply -auto-approve
```

Grafana and Prometheus are exposed via TLS:

```text
https://grafana.home.arpa
https://prometheus.home.arpa
```

Grafana admin credentials are generated by OpenTofu. Retrieve them with:

```bash
tofu -chdir=monitoring output -raw grafana_admin_user
tofu -chdir=monitoring output -raw grafana_admin_password
```

Grafana dashboards are provisioned from `monitoring/grafana/dashboards/*.json`. After adding or editing a dashboard, re-run the monitoring apply and restart Grafana so it reloads the files.

```bash
tofu -chdir=monitoring apply -auto-approve
kubectl -n monitoring rollout restart deploy/grafana
```

### Destroy the infrastructre

If you want to programmatically destroy the plan:

```bash
tofu destroy -auto-approve -refresh=false
```

## Easy deployment

In order to make easier the development of this repo an utility script [`scripts/deploy.sh`](scripts/deploy.sh) has been created to deploy full infrastructure from scratch following all described steps.

:warning: **Use with caution** due to the VMs cluster will be removed if option `-d` or `--destroy` is passed.

```bash
./scripts/deploy.sh
```

Run with `-h` or `--help` to see help documentation. Common options:

```text
--help            Show usage help.
--destroy         Destroy the cluster first and purge local state files.
--skip-ceph       Skip Rook Ceph operator/cluster/dashboard/CSI.
--skip-k8s-net    Skip MetalLB, ingress-nginx, cert-manager, Portainer.
--skip-portainer  Skip Portainer deployment (only if -n/--skip-k8s-net is not used).
--skip-monitoring Skip Prometheus/Loki/Grafana stack.
```

## References

### OpenTofu

- [Installing OpenTofu via Homebrew](https://opentofu.org/docs/intro/install/homebrew/)
- [Working with OpenTofu](https://opentofu.org/docs/intro/core-workflow/)
- [`bpg/proxmox` OpenTofu provider for Proxmox VE](https://search.opentofu.org/provider/bpg/proxmox/latest)
- [`bpg/proxmox` reference for `proxmox_virtual_environment_vm` resource](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm)

### Tutorials

- [Talos cluster on Proxmox with Terraform](https://olav.ninja/talos-cluster-on-proxmox-with-terraform)
