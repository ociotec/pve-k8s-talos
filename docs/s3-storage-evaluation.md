# S3-Compatible Storage Evaluation

## Introduction

This document tracks the evaluation of an S3-compatible storage service for the Kubernetes platform. The current direction is to keep external Ceph as the block and filesystem storage layer through Rook CSI, and add an S3 API service on top of Kubernetes rather than requiring Proxmox VE Ceph to expose RGW directly. For distributed object-store candidates, the Kubernetes worker VM disks used by the object store are expected to be local virtual disks, not Ceph-backed disks, following the same durability-layer separation used for Kafka.

This is a living decision document. Update it whenever S3 alternatives, evaluation criteria, final candidates, or the selected option change.

The deployment plan must support clusters with only three Kubernetes worker nodes. Larger clusters with tens of workers are possible later, but a viable baseline cannot require more than three workers unless the document explicitly marks that option as conditional.

## Evaluation Criteria

- **Open-source and licensing posture**: prefer clearly open-source, self-hostable projects with licensing that fits long-term platform use. AGPL-3.0 is acceptable for unmodified self-hosted use; the key obligation to plan for is publishing source for modified versions offered over a network.
- **S3 compatibility**: prioritize compatibility with common S3 clients, SDKs, multipart uploads, presigned URLs, bucket operations, policies, lifecycle, and application expectations.
- **Kubernetes fit**: prefer projects with Helm charts, operators, documented Kubernetes deployment patterns, and clean ingress / TLS integration.
- **Deployment control model**: track whether the service can be run from simple repository-owned manifests, rendered Helm output, or a dedicated operator / CRD layer. Helm and operators are acceptable, as with Rancher, but they add review and lifecycle complexity.
- **Web/admin console**: prefer a usable console for bucket, object, user, credential, and cluster administration. A console does not need to be part of the object store core if a companion component satisfies the same licensing, deployment, resource, maturity, and security criteria. Community consoles are acceptable but must be evaluated as part of the service.
- **Prometheus / Grafana observability**: require useful metrics for service health, request behavior, capacity, replication, and operational alerts.
- **High availability model**: prefer a clear multi-node model with documented behavior for node loss, pod rescheduling, and storage recovery.
- **Three-worker baseline**: prefer options that can run a meaningful HA deployment on exactly three Kubernetes worker nodes. Options requiring four or more storage nodes are acceptable only for larger clusters or if the infrastructure plan adds dedicated storage workers.
- **Backend storage fit**: evaluate whether the service should use local worker VM disks, local PVs, Ceph RBD PVCs, CephFS, or its own distributed storage layout. Distributed object stores should prefer local worker VM disks / local PVs so they own data placement and failure-domain behavior.
- **Resource footprint and modest hardware fit**: prefer options that can run comfortably on small worker nodes with low CPU and memory reservations. Track an initial CPU and memory budget per storage replica for repository-managed manifests. Treat these as starting requests / limits for a small HA deployment, not production capacity guarantees.
- **Geo-distribution potential**: useful but not mandatory. Prefer projects that can support future multi-site operation without a full redesign.
- **Operational complexity**: prefer systems that can be deployed and maintained safely by this repository's existing OpenTofu and Kubernetes automation model.
- **Maturity and project risk**: consider age, documentation quality, release cadence, community use, and whether the project is still evolving rapidly. Treat beta/pre-GA infrastructure without independently verifiable production references as high risk for repository-managed production use.

## Evaluated Options

Legend: 🟢 good fit, 🟡 acceptable or mixed fit, 🔴 poor fit or blocker. For deployment control, 🟢 means simple or repo-owned manifests, 🟡 means rendered Helm or operator-managed resources with extra review, and 🔴 means too heavy for this repository. Resource estimates assume a small HA baseline of at least three replicas where supported.

| Alternative | License / posture | S3 compatibility | Kubernetes fit | Deployment control model | Console and observability | HA and backend model | Planning CPU / RAM per replica | Maturity / operational use | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MinIO | 🔴 [License](https://docs.min.io/license/) posture blocks this platform; source remains [AGPLv3](https://github.com/minio/minio). | 🟢 Very strong. | 🟢 Mature K8s story. | 🟢 Manifests or rendered Helm; operator not required. | 🟡 Strong console and metrics, but license direction is a concern. | 🟢 Distributed store with erasure coding. | 🟡 2 CPU / 4Gi; 8Gi+ for heavier workloads. | 🟢 Mature and widely deployed. | **Discarded.** Known baseline, but license posture does not fit. |
| RustFS | 🟢 [Apache-2.0](https://docs.rustfs.com/concepts/introduction.html). | 🟢 Strong stated [S3 support](https://docs.rustfs.com/features/s3-compatibility); needs validation. | 🟢 K8s-oriented. | 🟡 Verify manifests vs Helm or operator. | 🟢 Console and [metrics](https://docs.rustfs.com/features/logging). | 🔴 [Distributed mode](https://docs.rustfs.com/installation/linux/multiple-node-multiple-disk.html) requires 4+ servers. | 🟡 2 CPU / 8Gi for PoC; [production guidance](https://docs.rustfs.com/installation/checklists/hardware-selection.html) is larger. | 🔴 Beta / pre-GA; no solid production references; recent [critical advisory](https://github.com/rustfs/rustfs/security/advisories/GHSA-h956-rh7x-ppgj). | **Watchlist.** Strong fit, but maturity risk is too high. |
| Garage | 🟢 [AGPL-3.0](https://garagehq.deuxfleurs.fr/documentation/); acceptable for unmodified self-hosted use. | 🟡 Good [core S3 support](https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/); advanced S3 gaps remain. | 🟢 [K8s deployment](https://garagehq.deuxfleurs.fr/documentation/cookbook/kubernetes/) documented. | 🟢 Repo-owned manifests are realistic. | 🟢 Needs companion UI; [metrics](https://garagehq.deuxfleurs.fr/documentation/reference-manual/monitoring/) built in. | 🟢 Replicated store for modest hardware and [multi-site](https://garagehq.deuxfleurs.fr/documentation/design/goals/). | 🟢 1 CPU / 1Gi; raise to 2Gi if needed. | 🟢 Mature enough for small and medium self-hosted use. | **Selected.** Best fit for 3-worker PoC, modest hardware, and local disks. |
| NooBaa | 🟢 [Apache-2.0](https://github.com/noobaa/noobaa-operator). | 🟡 S3 gateway; test target clients. | 🟢 Strong operator fit. | 🟡 Operator and CRDs are natural path. | 🟢 UI / CLI and Prometheus / Service Monitor patterns. | 🟡 Gateway over PVs, filesystems, or object stores. | 🟡 About 2 CPU / 4Gi per core or gateway replica, plus support pods. | 🟢 Proven in K8s / OpenShift ecosystems. | **Next candidate.** Good admin UX, but more gateway than primary store. |
| SeaweedFS | 🟢 [Apache-2.0](https://github.com/seaweedfs/seaweedfs). | 🟡 S3 plus filesystem and data-lake features. | 🟡 [Operator](https://github.com/seaweedfs/seaweedfs-operator) exists. | 🟡 Multi-component manifests or operator. | 🟢 Admin UIs and Prometheus / Grafana. | 🟡 Master, volume, filer, and S3 gateway stack. | 🟡 1 CPU / 2Gi per volume; closer to 2 CPU / 4Gi per node overall. | 🟢 Mature, but more day-2 work. | **Discarded for first pass.** Too much surface for the first S3 service. |
| s3gw | 🟢 [Apache-2.0](https://docs.s3gw.tech/). | 🟡 S3 over Ceph RGW components. | 🟢 [Helm chart](https://s3gw-docs.readthedocs.io/en/v0.16.0/helm-charts/) available. | 🟢 Rendered Helm can be repo-owned. | 🟡 UI exists; observability is less central. | 🔴 Durability belongs to the backing PV or filesystem. | 🟢 1 CPU / 2Gi gateway baseline. | 🟡 Plausible for simple S3 over durable PV. | **Discarded as primary.** Useful for S3 over Ceph RBD PVC, not distributed platform S3. |
| Apache Ozone | 🟢 Apache-2.0. | 🟡 Substantial [S3 gateway](https://ozone.apache.org/docs/core-concepts/architecture/s3-gateway). | 🔴 Oversized for this platform. | 🔴 Full multi-service stack. | 🟢 UIs and [Prometheus endpoints](https://ozone.apache.org/docs/administrator-guide/operations/observability/). | 🟡 Managers, datanodes, and S3 gateways. | 🔴 4 CPU / 8Gi+ per datanode-class replica, plus managers. | 🟢 Mature big-data storage project. | **Discarded.** Capable, but too large and complex. |
| Ceph RGW / Rook object store | 🟢 Open Ceph / Rook stack. | 🟢 Mature [Ceph RGW](https://docs.ceph.com/en/squid/radosgw/). | 🟡 Good for Rook-managed Ceph; external RGW endpoints also supported. | 🟡 Rook CRDs fit K8s, but depend on RGW topology. | 🟡 Mature [metrics](https://docs.ceph.com/en/squid/radosgw/metrics/); UI needs Ceph dashboard or S3 tooling. | 🔴 Best when RGW already exists or Rook owns Ceph. | 🟡 1-2 CPU / 2-4Gi per RGW pod; capacity dominated by Ceph. | 🟢 Very mature where RGW is part of the architecture. | **Discarded here.** No clean external PVE RGW path today. |
| Zenko CloudServer | 🟢 Apache-2.0 lineage. | 🟡 Useful S3 API target. | 🔴 Weak as primary K8s platform storage. | 🟡 Simple container manifests plausible. | 🔴 Weaker admin and observability story. | 🔴 Gateway-oriented, not full HA storage. | 🟢 1 CPU / 2Gi for light API tests. | 🟡 Useful for development and gateway scenarios. | **Discarded.** Does not fit HA platform-storage role. |

## Candidate Status

### RustFS

RustFS is no longer a final baseline candidate. Its feature fit is strong, but the maturity risk is too high for this repository today. As of May 17, 2026, the latest [GitHub release line](https://github.com/rustfs/rustfs/releases) is still `1.0.0-beta.*` and marked as pre-release. RustFS's own [beta announcement](https://rustfs.dev/announcing-rustfs-beta-the-high-performance-s3-compatible-open-source-storage-for-the-ai-era/) says the project is ready for broader real-world adoption and production validation, while still working toward a future GA release. Public third-party material found so far is integration / demo oriented, such as LINBIT's [RustFS + LINSTOR disaster-recovery walkthrough](https://linbit.com/blog/disaster-recovery-with-rustfs-linstor-in-kubernetes/), not a production case study. RustFS documentation also includes vendor-written solution pages and case-study claims, but those are not independently verifiable enough to offset the beta / pre-GA risk. The recent [gRPC hardcoded token authentication bypass advisory](https://github.com/rustfs/rustfs/security/advisories/GHSA-h956-rh7x-ppgj), fixed in `alpha.78`, is another signal that the project is still going through early production-hardening work.

Keep RustFS on the watchlist only. Reconsider it after GA, after several stable releases, and after credible production references appear for multi-node Kubernetes or bare-metal deployments.

### Garage

Garage is the default candidate for this repository because it directly matches the important operational constraints: three-worker deployments, modest hardware, low resource footprint, simple manifests, local disks, and future geo-distribution. It has a deliberate design for small-to-medium self-hosted multi-site deployments and exposes useful Prometheus metrics. The fact that Garage does not ship a rich first-party console is not intrinsically negative if the deployment includes a companion UI that independently satisfies the repository criteria.

For the PoC, evaluate Garage together with one UI path:

- `garage-ui`: Garage-specific web UI with Helm packaging and built-in no-auth / basic / OIDC modes; promising Kubernetes fit, but newer and should be validated carefully.
- `garage-webui`: lightweight Garage-specific admin UI with bucket, key, layout, object browser, and health / status features; attractive for a minimal PoC if authentication is handled by ingress / OIDC proxy.
- Stowage: generic S3 console / proxy with OIDC, RBAC, audit, quotas, multi-backend support, and optional Kubernetes operator; richer but adds a larger component than a Garage-specific UI.

The main Garage tradeoff remains S3 compatibility: it is good for many application use cases, but missing advanced S3 features can block some clients or backup / compliance workflows.

### NooBaa

NooBaa is a strong Kubernetes-native candidate with an operator, management UI, and flexible backing stores. It is attractive when the platform needs a managed S3 gateway with placement policies over PVs, filesystems, or other object stores. It is less direct than RustFS or Garage as a primary object store, and should be evaluated if gateway / data placement features become more important than a minimal object-store deployment.

## Chosen PoC Option

The current selected option for the proof of concept is **Garage**. This is a PoC decision, not a final production commitment.

RustFS is not a fallback for near-term implementation. It remains a watchlist item for future reevaluation if it reaches GA, demonstrates stable release maturity, and gains credible production references.

The initial implementation should validate the selected candidate against the intended storage model directly: dedicated underlying storage per object-store node, using local virtual disks attached to the Kubernetes worker VMs and exposed as local disks or local PVs. These worker VM disks must not be backed by Ceph. The object store should own data placement, replication, erasure coding, and failure-domain behavior from the start. Avoid using replicated Ceph RBD PVCs as the PoC default for distributed object-store candidates, because that would hide the real production tradeoffs behind a second durability layer. The PoC should also include one companion UI so the admin-console criterion is validated as a deployed service, not assumed from Garage alone.

If Garage does not validate on S3 compatibility for target clients or operational behavior, evaluate NooBaa next before reconsidering RustFS.

## Storage Backend Note

For distributed object stores such as RustFS, Garage, or SeaweedFS, using replicated Ceph RBD underneath duplicates the durability layer. This is similar to running Kafka's own replicated log on top of replicated Ceph volumes: it can work, but it obscures which layer is responsible for resilience, wastes capacity, adds write amplification, and makes failure analysis less direct. The preferred model is one dedicated local worker VM disk or local PV per storage pod, letting the object store own replication, placement, and failure-domain behavior.

For simpler S3 gateways such as s3gw, Ceph RBD underneath is more natural because the gateway delegates durability to the backing PV. That model is easier but provides less native object-store distribution.

## References

- RustFS documentation: <https://docs.rustfs.com/>
- RustFS beta announcement: <https://rustfs.dev/announcing-rustfs-beta-the-high-performance-s3-compatible-open-source-storage-for-the-ai-era/>
- RustFS GitHub releases: <https://github.com/rustfs/rustfs/releases>
- RustFS gRPC authentication-bypass advisory: <https://github.com/rustfs/rustfs/security/advisories/GHSA-h956-rh7x-ppgj>
- RustFS hardware selection: <https://docs.rustfs.com/installation/checklists/hardware-selection.html>
- RustFS multiple-node multiple-disk installation: <https://docs.rustfs.com/installation/linux/multiple-node-multiple-disk.html>
- LINBIT RustFS integration walkthrough: <https://linbit.com/blog/disaster-recovery-with-rustfs-linstor-in-kubernetes/>
- Garage documentation: <https://garagehq.deuxfleurs.fr/documentation/>
- Garage UI Helm chart: <https://artifacthub.io/packages/helm/garage-ui/garage-ui>
- Garage WebUI Docker image: <https://hub.docker.com/r/khairul169/garage-webui>
- Stowage S3 console: <https://stowage.dev/>
- GNU AGPL-3.0: <https://www.gnu.org/licenses/agpl-3.0.en.html>
- NooBaa operator: <https://github.com/noobaa/noobaa-operator>
- SeaweedFS operator: <https://github.com/seaweedfs/seaweedfs-operator>
- s3gw documentation: <https://docs.s3gw.tech/>
- Apache Ozone S3 Gateway: <https://ozone.apache.org/docs/core-concepts/architecture/s3-gateway>
- Rook object storage: <https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/>
- MinIO Software License: <https://docs.min.io/license/>
- MinIO GitHub license posture: <https://github.com/minio/minio>
