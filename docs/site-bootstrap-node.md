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
│ Discovery │ Bootstrap tools     │       │ Discovery │ Gitea │ Tools       │
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
| Bootstrap node | Docker Compose service stack | Pending |
| Bootstrap node | Gitea with PostgreSQL for Git, images, and charts | Pending |
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
| Publish approved artifacts | Store local copies in Gitea | Pull local artifacts |
| Manage connected clusters | Bootstrap and recover Kubernetes | Reconcile locally when offline |

Do not run Jenkins or build application images at every target site. Build
once, verify once, and promote the same immutable artifacts.

## Helm, OCI, and Gitea

Helm 3 only needs a client and access to the Kubernetes API. There is no
required Helm server inside the cluster.

Harbor remains the authoritative registry in the development environment. It
stores approved images and charts before they are added to a release bundle.

At an offline site, Gitea is the recommended local service for three purposes:

```text
Gitea
├── Git repositories
└── OCI registry
    ├── container images
    └── OCI Helm charts
```

This keeps the bootstrap VM small and simple:

- Gitea is open source and designed for resource-constrained servers;
- one application and certificate replaces separate Git, image-registry, and
  chart-registry services;
- its OCI registry supports both container images and Helm charts;
- shared blobs are deduplicated and cleanup rules can limit retained versions;
- the UI, API, users, organizations, tokens, and SSH/HTTPS access remain
  available when operators need them.

Gitea supports PostgreSQL and recommends selecting the final database type
from the first installation because later database conversion is not a
well-tested path. PostgreSQL is preferred over SQLite here for stronger
operational consistency and future growth.

```text
Docker Compose
├── Gitea
└── PostgreSQL
```

The PostgreSQL major version must be supported, pinned, and included in the
offline release bundle. Minor upgrades and major migrations must be deliberate
rather than following a floating `latest` tag.

Gitea documents 2 CPU and 1 GB of memory as sufficient for a small workload.
A practical bootstrap VM baseline with PostgreSQL, Discovery Service, and
deployment tools is:

| Resource | Initial sizing |
| --- | ---: |
| CPU | 4 vCPU |
| Memory | 8 GB |
| OS disk | 40 GB |
| Expandable data disk | 128–250 GB |

Artifact volume, especially retained container images, determines disk usage.
Git repositories and Helm charts are normally much smaller.

### Container runtime model

Long-running application services on the bootstrap VM should run as
containers. Host-level responsibilities remain outside containers:

```text
Debian host
├── Docker Engine
│   ├── Docker Compose
│   └── containers
│       ├── Talos Discovery Service
│       ├── Gitea
│       └── PostgreSQL
├── TLS reverse proxy and host trust
├── disks, mounts, backups, and restore
└── deployment CLI tools and provider mirror
```

The current VM implementation already installs Docker and runs Talos Discovery
Service as a container managed by systemd. The planned implementation should
add Docker Compose v2 and define Gitea and PostgreSQL as one declarative stack.

Docker Compose is preferred to individual `docker run` commands once services
have dependencies. It provides one versioned definition for networks, volumes,
health checks, restart policies, and startup order.

Docker Swarm is not recommended for a single bootstrap VM:

- a one-node swarm still fails when that VM fails;
- it adds manager state, overlay networking, and another recovery procedure;
- moving a container does not move or recover PostgreSQL and OCI data;
- real Swarm high availability requires multiple hosts, manager quorum, and
  replicated storage.

VM backup or a passive replacement is simpler and provides the relevant
recovery model. Swarm should only be reconsidered if a site later provides at
least three independent infra hosts and a separate design for PostgreSQL and
artifact-storage high availability.

Gitea data and PostgreSQL data must use separate persistent paths on the
dedicated data disk. PostgreSQL must expose no host port, accept connections
only from the private Compose network, use a health check, and store its
password outside the versioned Compose file. Backups must capture both the
Gitea data directory and a consistent PostgreSQL backup.

Recommended identities:

| Identity | Access |
| --- | --- |
| Bundle importer | Write Git and OCI |
| Argo CD | Read Git and Helm artifacts |
| Talos and Kubernetes | Read container images |
| Deployment workflow | Write only repositories that synchronize runtime state |

The central environment remains responsible for building, scanning, signing,
and approving artifacts. The offline Gitea instance distributes those
immutable artifacts locally; it does not need to repeat Harbor's scanning or
replication functions.

A suitable cleanup policy keeps at least the three most recently published
versions of every image or chart, all versions newer than a safety period, and
explicit `stable` or `rollback` versions. Deployments should use versions or
digests rather than `latest`.

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
 Bootstrap node verifies and imports
 ├── Git revisions ────────────────► Gitea Git
 ├── images and Helm charts ───────► Gitea OCI
 ├── OpenTofu providers
 ├── Talos assets and images
 └── deployment tools
          │
          ▼
 Create Talos and Kubernetes
          │
          ▼
 Install local Argo CD
          │
          ▼
 Argo CD reads Gitea ──► applications
```

A central Argo CD instance cannot continuously manage a disconnected cluster.
Run Argo CD in each offline target cluster and point it only at site-local Git
and OCI endpoints. Argo CD Core is suitable when no local UI, OIDC, or Argo CD
API is required; the full installation remains an option for sites that need
those interfaces.

### Offline installation boundary

Argo CD cannot install itself into a cluster that does not yet exist. The
initial deployment has a small, explicit bootstrap boundary:

```text
Bootstrap node                         Target cluster
──────────────                         ──────────────
1. Start Gitea + PostgreSQL with Compose
2. Verify release bundle
3. Import Git and OCI into Gitea
4. Create Talos and Kubernetes ──────► cluster becomes available
5. Install Argo CD from local assets ─► Argo CD becomes available
6. Seed the root Application ─────────► Argo CD takes control
```

Step 4 uses the existing OpenTofu platform deployment path. Steps 5–6 are
planned additions and must also use only bundled manifests, charts, tools, and
images. After the root `Application` is created:

```text
Gitea Git ───────► Argo CD ───────► Application desired state
Gitea Helm OCI ──► Argo CD
Gitea images ─────────────────────► Talos and Kubernetes runtimes
```

Argo CD then continuously corrects drift and deploys later releases from the
local Gitea instance. The platform itself remains managed by the existing
OpenTofu deployment path for now. A release update repeats bundle verification
and import, then advances the approved application Git revision. It does not
rebuild artifacts at the site.

### Why Argo Rollouts is not part of the baseline

Argo Rollouts is useful when old and new versions can run at the same time
during Blue/Green or Canary delivery. That is not true for singleton services
whose processing is stateful and ordered, such as an event processor where
the next Kafka event depends on previous events.

```text
Unsupported baseline                 Required replacement
────────────────────                 ────────────────────
old version ─┐                       stop old version
             ├── overlap                     │
new version ─┘                               ▼
                                        start new version
```

These services should normally use one replica with a Kubernetes Deployment
`Recreate` strategy. The application must stop consuming, finish or abort the
current unit of work safely, persist state and offsets, and exit before the new
version starts. Kafka can retain incoming events during the controlled
interruption.

Argo CD still controls the desired version and performs rollback through a Git
revision change. Argo Rollouts may be added later for stateless or replicated
services that explicitly support concurrent versions, but installing it is
not required for the baseline architecture.

## Local Git requirement

The repository deployment workflow synchronizes clean platform and environment
repositories before and after deployment:

```text
Platform repository ──┐
                      ├── Gitea on the bootstrap node
Environment repository┘
```

An offline site therefore needs Gitea to act as the local upstream. The
deployment identity requires limited write access because the deployment
workflow records allowlisted runtime state. Copying only working directories
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
Restore Gitea and PostgreSQL data
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
- dedicated Gitea and PostgreSQL data storage;
- consistent backups of Gitea, PostgreSQL, certificates, and configuration;
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
   Compose + Gitea + PostgreSQL
                 │
3. Complete offline bootstrap
   Git + OCI + Talos images + providers + signed bundles
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
- Gitea overview and resource requirements:
  <https://docs.gitea.com/>
- Gitea OCI container and Helm chart registry:
  <https://docs.gitea.com/usage/packages/container/>
- Gitea package deduplication and cleanup:
  <https://docs.gitea.com/usage/packages/storage/>
- Gitea installation with Docker and PostgreSQL:
  <https://docs.gitea.com/installation/install-with-docker/>
- Gitea database preparation:
  <https://docs.gitea.com/installation/database-prep/>
- Docker Compose on a single production server:
  <https://docs.docker.com/compose/how-tos/production/>
- Docker Swarm mode:
  <https://docs.docker.com/engine/swarm/>
- Argo CD Helm integration:
  <https://argo-cd.readthedocs.io/en/stable/user-guide/helm/>
- Argo CD Core:
  <https://argo-cd.readthedocs.io/en/stable/operator-manual/core/>
- Argo Rollouts:
  <https://argoproj.github.io/argo-rollouts/>
- Kubernetes Deployment strategies:
  <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy>
- OpenTofu provider mirrors:
  <https://opentofu.org/docs/cli/commands/providers/mirror/>
