# External Ceph Storage Architecture

## Scope

This specification describes storage when `ceph_mode = "external"`: a native
Ceph cluster operated by Proxmox VE (PVE) supplies storage to Kubernetes through
Rook and Ceph CSI. It does not describe the repository's internal Rook mode.

## Ownership boundary

```text
 PVE layer                                      Kubernetes layer
 ┌─────────────────────────────────────┐       ┌─────────────────────────────┐
 │ PVE nodes                           │       │ Rook operator               │
 │  ├─ Ceph MON / MGR / OSD daemons    │◄─────►│ External CephCluster CR     │
 │  ├─ Physical disks and CRUSH layout │  Ceph │ CSI provisioners/plugins    │
 │  ├─ Pool durability and PG health   │  net  │ StorageClasses              │
 │  └─ MDS daemons for CephFS          │       │ PVCs → PVs → pod mounts     │
 └─────────────────────────────────────┘       └─────────────────────────────┘
          ▲                                             │
          │ PVE API + SSH/ceph CLI                      │ RBD or CephFS I/O
          └──────── deployment reconciliation ──────────┘
```

PVE owns the Ceph cluster lifecycle: hosts, disks, OSDs, monitors, managers,
networking, CRUSH topology, recovery, upgrades, and overall health. This
repository assumes that cluster already exists. It creates or reconciles only
the pools, CephFS filesystems, MDS instances, and CSI subvolume groups requested
for the Kubernetes cluster.

Talos VM disks are a separate PVE storage path. OpenTofu places them on
the configured PVE datastore. That datastore may itself be backed by PVE Ceph,
but it is independent from Kubernetes PVC provisioning.

## Desired state and reconciliation

The cluster-specific desired state defines:

- the Ceph FSID, monitor v1 endpoints, optional manager Prometheus endpoints,
  SSH management host, and Ceph credentials;
- a cluster-specific naming prefix;
- enabled replicated or erasure-coded RBD and CephFS profiles, including pool
  names, PG counts, replica sizes, `min_size`, and EC `k+m` geometry.

The Ceph deployment applies the following sequence:

```text
 desired Ceph state
        │
        ├─► PVE Ceph resources
        │     1. Reconcile RBD pools through the PVE API and Ceph CLI over SSH
        │     2. Reconcile CephFS pools, filesystem, MDS, and `csi` subvolume group
        │
        └─► Kubernetes resources
              3. Create monitor Secret and endpoint ConfigMap in `rook-ceph`
              4. Apply CephCluster with `spec.external.enable = true`
              5. Create RBD and CephFS StorageClasses
              6. Let Rook manage CSI provisioners and node plugins
              7. Restart CSI only when effective external connection data changes
```

External operations are idempotent and serialized. Replicated and EC pool
settings are converged, PG autoscaling is enabled, and EC data pools enable
overwrites. CephFS metadata and initial data pools remain replicated; an EC
profile adds an EC data pool and directs the CSI subvolume group to it.

Rook does **not** deploy MON, MGR, OSD, or MDS pods in external mode. The
external `CephCluster` represents the connection and reports `Connected`; the
actual data-plane daemons remain on PVE.

## Pool models

### Replicated pools

Each object is stored in multiple complete copies across different PVE Ceph
hosts. The replica `size` defines the number of copies and `min_size` defines
the minimum number required for I/O. This model has the simplest recovery and
best small-write behavior, at the cost of higher raw-capacity consumption.

```text
 Example: size=3, min_size=2

                    ┌──────────────┐
 Application write ─► Ceph object  │
                    └──────┬───────┘
             ┌─────────────┼─────────────┐
             ▼             ▼             ▼
       ┌────────────┐  ┌────────────┐  ┌────────────┐
       │ PVE host A │  │ PVE host B │  │ PVE host C │
       │ full copy  │  │ full copy  │  │ full copy  │
       └────────────┘  └────────────┘  └────────────┘

 Logical data:          100 GB
 Raw capacity consumed: 300 GB = 300%
 Storage overhead:      200 GB = 200%

 Three complete copies are stored; I/O can continue with two available copies.
```

- Replicated RBD uses one replicated pool for block-volume data and metadata.
- Replicated CephFS uses separate replicated metadata and data pools. PVE-hosted
  MDS daemons provide filesystem metadata services.

### Erasure-coded pools

Objects are split into `k` data chunks and `m` coding chunks across PVE Ceph
hosts. This reduces raw-capacity overhead but increases computational and
recovery cost. EC data pools enable overwrites for RBD and CephFS use.

```text
 Example: k=2 data chunks, m=1 coding chunk

                    ┌──────────────┐
 Application write ─► Ceph object  │
                    └──────┬───────┘
                    split + encode
             ┌─────────────┼─────────────┐
             ▼             ▼             ▼
       ┌────────────┐  ┌────────────┐  ┌────────────┐
       │ PVE host A │  │ PVE host B │  │ PVE host C │
       │ data D1    │  │ data D2    │  │ coding C1  │
       └────────────┘  └────────────┘  └────────────┘

 Logical data:          100 GB
 Raw capacity consumed: 150 GB = 150%
 Storage overhead:       50 GB =  50%

 Any two chunks reconstruct the object; one host/chunk may be unavailable.
```

- EC RBD keeps RBD metadata in a small replicated pool and stores volume data
  in the EC pool.
- EC CephFS keeps filesystem metadata and its initial/default data pool
  replicated, adds an EC data pool, and places CSI-created subvolumes there.

These percentages are theoretical data-placement ratios. Actual usable cluster
capacity is lower after Ceph metadata, replicated metadata pools, operational
headroom, uneven placement, and recovery capacity are considered.

## Kubernetes consumption

The infrastructure creates and maintains all four StorageClass profiles shown
below. It does not impose one global storage model on every workload. Each
deployed application selects the StorageClass that best fits its requirements
in its PVC:

- replicated or EC, according to the required performance, recovery behavior,
  and capacity efficiency;
- RBD block storage or CephFS file storage, according to the access semantics:
  typically single-node read/write block volumes or shared multi-node filesystems.

| Storage profile | CSI driver | Ceph target | Typical access |
| --- | --- | --- | --- |
| Replicated RBD | `rook-ceph.rbd.csi.ceph.com` | Replicated RBD pool | Block, usually RWO |
| EC RBD | `rook-ceph.rbd.csi.ceph.com` | Replicated metadata pool + EC data pool | Block, usually RWO |
| Replicated CephFS | `rook-ceph.cephfs.csi.ceph.com` | Replicated CephFS data pool | Shared filesystem, RWX |
| EC CephFS | `rook-ceph.cephfs.csi.ceph.com` | Replicated metadata/default pools + EC data pool | Shared filesystem, RWX |

All generated StorageClasses allow expansion and use `reclaimPolicy: Delete`.
An application requests a class in a PVC; Ceph CSI then creates an RBD image or
CephFS subvolume in the selected external pool and mounts it on the Talos node.

```text
 Pod ─► PVC ─► StorageClass ─► Ceph CSI ─► PVE Ceph pool/filesystem
                         create/map/mount │ read and write directly
```

## Credentials, monitoring, and deletion

- External connection data is materialized as the `rook-ceph-mon` Secret and
  `rook-ceph-mon-endpoints` ConfigMap. Secrets belong only in the protected real
  cluster repository; they must not be copied to shared files or console output.
- `client.admin` is required when this deployment must manage pools/filesystems
  or use external CephFS. A health-check key is sufficient only for a basic
  read-only external connection when no admin operation is needed.
- Ceph health is checked through the external `CephCluster`. Optional PVE
  `ceph-mgr` Prometheus targets provide pool and PG metrics to monitoring.
- A normal destroy does not implicitly purge PVE data. External Ceph resources
  are removed only by an explicitly authorized destroy using
  `--purge-external-ceph`; the purge temporarily enables pool deletion and then
  restores the previous Ceph monitor setting.
