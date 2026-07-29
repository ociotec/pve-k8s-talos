# Site Bootstrap Node and Offline Delivery

## Purpose

This architecture supports both connected and fully offline Kubernetes sites.
It separates artifact creation from site installation and application runtime.

```text
DEVELOPMENT AND MANAGEMENT CLUSTER
┌───────────────────────────────────────────────────────────────────────────┐
│ Jenkins       Build and test                                              │
│ Harbor        Store images and Helm charts                                │
│ Argo CD       Deploy to connected clusters                                │
└────────────────┬─────────────────────────────────────────┬────────────────┘
                 │                                         │
        connected delivery                       signed release bundle
                 │                                         │
                 ▼                                         ▼
            ONLINE SITE                              OFFLINE SITE
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│ BOOTSTRAP NODE                  │       │ BOOTSTRAP NODE                  │
│ Discovery │ Bootstrap tools     │       │ Discovery │ OCI │ Git │ Tools   │
└────────────────┬────────────────┘       └────────────────┬────────────────┘
                 │ bootstrap                               │ bootstrap + artifacts
                 ▼                                         ▼
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│ TARGET KUBERNETES CLUSTER       │       │ TARGET KUBERNETES CLUSTER       │
│ Platform │ Applications         │       │ Platform │ Argo CD │ Apps       │
│ Managed by central Argo CD      │       │ Reconciled by local Argo CD     │
└─────────────────────────────────┘       └─────────────────────────────────┘
```

## The bootstrap node

A site bootstrap node is a small VM outside Kubernetes. It provides everything
needed to create or recover the local cluster without depending on that
cluster.

```text
Bootstrap node
      │
      ├── starts Talos and Kubernetes
      ├── supplies local artifacts and deployment tools
      └── remains available for upgrades and recovery
```

It is not a worker, does not join the control plane, and does not run business
applications. This repository represents these VMs under
`infra-vms/<name>/`.

### Why outside Kubernetes?

Hosting the only registry inside the target cluster creates a circular
dependency:

```text
Cluster needs images ──► registry needs cluster ──► cluster cannot start
```

A registry on the bootstrap node breaks that cycle:

```text
Bootstrap registry ──► cluster starts ──► in-cluster services start
```

## Service placement and status

Status means availability in this repository, not the live state of a specific
environment.

| Location | Capability | Status |
| --- | --- | --- |
| Bootstrap node | VM, static networking, extra disks, trusted CA | Available |
| Bootstrap node | Docker runtime | Available |
| Bootstrap node | Talos Discovery Service with TLS | Available |
| Bootstrap node | Local OCI registry | Pending |
| Bootstrap node | Local Git upstreams | Pending |
| Bootstrap node | OpenTofu provider mirror and deployment tools | Pending |
| Bootstrap node | Signed bundle import, verification, and backup | Pending |
| Target cluster | Networking, ingress, certificates, and load balancing | Available |
| Target cluster | Ceph storage, identity, and observability | Available |
| Development cluster | Jenkins CI | Proposed; not provided by this repository |
| Development cluster | Authoritative Harbor registry | Proposed; not provided by this repository |
| Development cluster | Central Argo CD | Proposed; not provided by this repository |
| Offline target cluster | Local Argo CD | Proposed; not provided by this repository |

Actual platform-service enablement remains environment-specific.

### Placement rule

| Development cluster | Bootstrap node | Target cluster |
| --- | --- | --- |
| Build and test software | Make the site self-sufficient | Run applications |
| Publish approved artifacts | Store local copies | Pull local artifacts |
| Manage connected clusters | Bootstrap and recover Kubernetes | Reconcile locally when offline |

Do not run Jenkins or build application images at every target site. Build
once, verify once, and promote the same immutable artifacts.

## Helm and the OCI registry

Helm 3 only needs a client and access to the Kubernetes API. There is no
required Helm server inside the cluster.

One OCI registry can store both kinds of artifact:

```text
OCI registry
├── container images
└── Helm charts
```

Therefore, Harbor can be the central source for both images and charts. A
separate ChartMuseum service is unnecessary.

Recommended model:

| Location | Recommendation |
| --- | --- |
| Development cluster | Harbor as the authoritative registry |
| Small offline site | Lightweight OCI registry on the bootstrap node |
| Larger offline site | Harbor when its UI, RBAC, retention, or scanning justify the extra resources |

A proxy cache is insufficient for a fully offline site. Every required
artifact must be imported before it is needed.

## Deployment flows

### Connected sites

```text
Code
 │
 ▼
Jenkins ──► image + Helm chart ──► Harbor
 │
 └───────► desired version ──────► Git
                                      │
                                      ▼
                                Central Argo CD
                                      │
                                      ▼
                               Connected clusters
```

Jenkins should build and publish. Argo CD should deploy, so CI does not need
target-cluster credentials.

### Offline sites

```text
Jenkins + Harbor + Git
          │
          ▼
 Signed release bundle
          │
          ▼
 Bootstrap node imports
 ├── images and Helm charts
 ├── Git revisions
 ├── OpenTofu providers
 ├── Talos assets
 └── deployment tools
          │
          ▼
 Local Argo CD ──► local applications
```

A central Argo CD instance cannot continuously manage a disconnected cluster.
Run Argo CD in each offline target cluster and point it only at site-local Git
and OCI endpoints.

For a small first deployment, an operator may run Helm from the bootstrap node.
This works, but does not continuously correct configuration drift as Argo CD
does.

## Local Git requirement

The repository deployment workflow synchronizes clean platform and environment
repositories before and after deployment:

```text
Platform repository ──┐
                      ├── local Git upstream on bootstrap node
Environment repository┘
```

An offline site therefore needs local Git upstreams. These can be a small Git
service or bare repositories served over SSH. Copying only working directories
is not an equivalent replacement.

## Release bundle

The release bundle is the controlled unit moved into an offline site.

```text
release-bundle/
├── release-lock.yaml       versions and immutable digests
├── checksums.txt
├── signatures/
├── git/
├── oci/                    images and Helm charts
├── opentofu-providers/
├── talos/
└── tools/
```

The import process should:

1. verify signatures and checksums;
2. verify the expected release and CPU architecture;
3. confirm that all declared artifacts are present;
4. update Git only with approved revisions;
5. reject undeclared Internet dependencies.

Import and deployment should be separate approval events. Bundles must not
contain unrelated kubeconfigs, private keys, state files, or plaintext
application secrets.

## Recovery and availability

```text
Recover bootstrap VM
        │
Restore registry and Git
        │
Create Talos/Kubernetes cluster
        │
Deploy platform and local Argo CD
        │
Restore applications from local Git and OCI
```

The target cluster may keep running while the bootstrap node is unavailable,
but image pulls, node replacement, upgrades, and full recovery may fail.

Minimum safeguards:

- HTTPS and trusted certificates;
- separate import and read-only pull identities;
- immutable digests and signed release bundles;
- dedicated artifact storage;
- backups of registry, Git, certificates, and configuration;
- a second copy of the latest approved release;
- a tested restore procedure.

One bootstrap VM is a reasonable starting point, but it is a site-level single
point of failure. Critical sites should have a recoverable VM backup or a
passive replacement.

## Implementation sequence

```text
1. Connected CI/CD
   Jenkins + Harbor + central Argo CD
                 │
2. Site artifacts
   Local OCI registry + Talos images
                 │
3. Complete offline bootstrap
   Git + providers + tools + signed bundles
                 │
4. Local GitOps
   Argo CD in each offline cluster
                 │
5. Recovery tests and redundancy
```

## References

- Talos air-gapped environments:
  <https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/air-gapped>
- Talos image-cache registry mirror:
  <https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/images-container-runtime/image-cache-registry-mirror>
- Helm OCI registries:
  <https://helm.sh/docs/topics/registries/>
- Harbor OCI Helm charts:
  <https://goharbor.io/docs/main/working-with-projects/working-with-oci/working-with-helm-oci-charts/>
- Argo CD Helm integration:
  <https://argo-cd.readthedocs.io/en/stable/user-guide/helm/>
- OpenTofu provider mirrors:
  <https://opentofu.org/docs/cli/commands/providers/mirror/>
