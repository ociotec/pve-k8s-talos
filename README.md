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
watch -n1 kubectl get pods -n rook-ceph
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
watch -n1 kubectl get pods -n rook-ceph
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

Run with `-h` or `--help` to see help documentation.

## Other things

### Portainer

Just apply its manifest (it's already updated to use Rook Ceph block Erasure Coded CSI):

```bash
kubectl apply -f portainer/portainer.yaml
```

Access the web on HTTPS port `30779` for instance: `https://<any-worker-IP>:30779/`, on first access you will need to create `admin` user password.

### MetalLB & NGINX ingress controller

Just apply the MetalLB manifest:

```bash
# First we create MetalLB infra
kubectl apply -f k8s-net/metallb-native.yaml
# Check till all pods are running
kubectl -n metallb-system get pods
# Something similar to this should be displayed
NAME                          READY   STATUS    RESTARTS   AGE
controller-66bdd896c6-qsjbp   1/1     Running   0          20m
speaker-7clgh                 1/1     Running   0          20m
speaker-7thk5                 1/1     Running   0          20m
speaker-8ldr4                 1/1     Running   0          20m
speaker-9mnhw                 1/1     Running   0          20m
speaker-jdkws                 1/1     Running   0          20m
speaker-npnvm                 1/1     Running   0          20m
speaker-smv26                 1/1     Running   0          20m
speaker-t4qbt                 1/1     Running   0          20m
```

Edit the IP pool manifest to assign a dedicated & free IP addresses pool on your local network (i.e. from `192.168.1.70` to `192.168.1.79`):

```bash
kubectl apply -f k8s-net/metallb-pool.yaml
```

Finally create the NGINX ingress controller:

```bash
kubectl apply -f k8s-net/ingress-nginx-controller.yaml
```

To check if it's working we could setup a basic web service to check if local IP address is assgined and it works:

```bash
# Create a whoami deployment & expose it on port 80
kubectl create deployment whoami --image=traefik/whoami
kubectl expose deployment whoami --port 80
# Update the service to LoadBalancer type
kubectl patch svc whoami -p '{"spec":{"type":"LoadBalancer"}}'
# Check if it gets an external IP address of the dedicated pool
kubectl get svc whoami
# Something similar to this should be displayed
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)        AGE
whoami   LoadBalancer   10.102.8.197   192.168.1.71   80:31213/TCP   19m
# Access via CURL to the service on the external IP
curl http://192.168.1.71
# Something similar to this should be displayed
Hostname: whoami-5cbdff98fc-5lrqp
IP: 127.0.0.1
IP: ::1
IP: 10.244.6.16
IP: fe80::bc29:2aff:fee2:1f1c
RemoteAddr: 10.244.3.0:12411
GET / HTTP/1.1
Host: 192.168.1.71
User-Agent: curl/8.7.1
Accept: */*
```

## References

### OpenTofu

- [Installing OpenTofu via Homebrew](https://opentofu.org/docs/intro/install/homebrew/)
- [Working with OpenTofu](https://opentofu.org/docs/intro/core-workflow/)
- [`bpg/proxmox` OpenTofu provider for Proxmox VE](https://search.opentofu.org/provider/bpg/proxmox/latest)
- [`bpg/proxmox` reference for `proxmox_virtual_environment_vm` resource](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm)

### Tutorials

- [Talos cluster on Proxmox with Terraform](https://olav.ninja/talos-cluster-on-proxmox-with-terraform)
