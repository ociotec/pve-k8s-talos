# VPA and Goldilocks

## Purpose and status

Vertical Pod Autoscaler (VPA) estimates CPU and memory requests for Kubernetes
containers from observed usage. Goldilocks creates VPA objects for selected
workloads and presents their recommendations in a web dashboard.

Both projects are open source under Apache-2.0. Their self-hosted components
have no licence fee; running them still consumes cluster resources. Fairwinds'
commercial services are separate and are not required by this integration.

This document describes the implemented design, not a completed rollout.
Consolidation and end-to-end authentication validation remain pending. The agent
[adoption workflow](agent-workflows/enable-vpa-goldilocks-in-cluster.md) deliberately
contains only previously consolidated steps; do not treat this specification as
evidence that installation has succeeded.

## Integration

The deployment section is `monitoring`, with a Keycloak client configured through
`identity` and `identity-config`.

- VPA chart `5.1.0` installs its CRDs and recommender `1.7.1`.
- The updater and admission controller are disabled. No VPA component changes
  requests or evicts workload pods in this design.
- Goldilocks `v4.16.2` is managed by typed Kubernetes resources in OpenTofu.
  The upstream chart does not expose controller probes or workload priorities.
  The controller uses `/healthz`; the dashboard uses `/health`.
- Existing Metrics Server supplies metrics. No second Metrics Server is installed.
- The dashboard always runs with `--enable-cost=false`: the external Fairwinds
  cost integration, signup form and associated scripts are disabled. This is a
  fixed platform policy, not a cluster setting.
- `all_namespaces` defaults to `true`; controller and dashboard then run with
  `--on-by-default=true`, covering all current and future namespaces without
  maintaining a namespace list or labeling them. Set `all_namespaces=false`
  to use namespace opt-in labels (`goldilocks.fairwinds.com/enabled=true`) instead.
  An explicit `goldilocks.fairwinds.com/enabled=false` namespace label remains
  an upstream-supported exclusion; no exclusions are configured by this module.
- Global discovery does not transfer ownership of namespaces to this module.
  Goldilocks owns the generated VPA objects, with default update mode `Off`.
  Legacy opt-in labels are retained but no longer managed during migration to
  avoid deleting existing VPAs while an old controller is still running.
  Workload-specific mode
  overrides can supersede the namespace default, but automatic updates remain
  unavailable because updater and admission controller are not deployed.

The dashboard has a ClusterIP service and an HTTPS NGINX Ingress protected by
`oauth2-proxy`. A separate `/oauth2` Ingress handles login and callbacks.
The confidential Keycloak client is `goldilocks`, with authorization code flow,
PKCE and a groups claim. Logical groups and their configured LDAP groups are
accepted; defaults are `k8s-admins` and `monitoring-view`.

Group access grants visibility to all selected namespaces, not per-user namespace
isolation. The Ingress protects external access; ClusterIP access from inside the
cluster does not pass through that authentication boundary.

TLS uses the existing certificate catalog. Preissued mode materializes the TLS
secret from certificate files; CA-issuer mode creates a cert-manager Certificate.
The proxy trusts the configured identity root CA. Persistent client/cookie
secrets live only in the real cluster's credential store. Pod checksum annotations
trigger proxy rollouts when its secrets or CA change.

## Configuration contract

An optional cluster file `vpa-goldilocks.auto.tfvars` configures the monitoring
module. Both components are enabled by default, including when this file is
absent. Namespace discovery defaults to global. The versioned sample documents the input
and sizing overrides.

```hcl
vpa_goldilocks = {
  vpa_enabled        = true
  goldilocks_enabled = true
  all_namespaces     = true # Default; false switches to label-based opt-in.
  keycloak_realm     = "company"
}
```

By default the hostname is `goldilocks.<cluster-domain>`, with TLS secret
`goldilocks-tls`. Optional `hostname`, `tls_secret_name` and `allowed_groups`
override these defaults. Configure the corresponding Keycloak client redirect
URI as `https://goldilocks.example.com/oauth2/callback`; if the hostname is
overridden, update the client's URL as well.

The optional file is linked only into `out/monitoring`. Identity must be applied
before monitoring so its outputs contain the new client. Hard preconditions block
Goldilocks without VPA, a valid identity client, allowed groups or OAuth secrets.
The Keycloak realm remains a required cluster-specific choice when Goldilocks is
enabled; it is not inferred from other services. Existing clusters without this
integration must configure the realm and identity client before their next
monitoring deployment, or set both `vpa_enabled` and `goldilocks_enabled` to
`false`. To keep VPA without the authenticated web UI, disable only Goldilocks.

Every deployed container has CPU/memory requests and limits, with memory
request equal to limit. Controllers use infrastructure priorities and ownership
labels. The recommender and Goldilocks controller expose metrics through the
existing annotation-based Prometheus discovery.

| Container | CPU request / limit | Memory request = limit |
| --- | --- | --- |
| VPA recommender | 100m / 500m | 512Mi |
| Goldilocks controller | 50m / 200m | 256Mi |
| Goldilocks dashboard | 50m / 200m | 256Mi |
| oauth2-proxy | 50m / 200m | 128Mi |

## Prometheus metrics and Grafana

The recommender and Goldilocks controller use pod annotations
`prometheus.io/scrape`, `prometheus.io/port` and `prometheus.io/path` for discovery.
Pod labels identify the application and component on the resulting targets;
labels alone do not enable scraping.

With VPA enabled, kube-state-metrics also watches VPA objects and exposes
`kube_verticalpodautoscaler_info`, `kube_verticalpodautoscaler_status_condition`
and `kube_verticalpodautoscaler_recommendation`. Recommendations carry namespace,
target kind/name, container, resource, unit and bound labels. CPU is measured in
cores and memory in bytes; bounds are `lowerBound`, `target`, `upperBound` and
`uncappedTarget`. Objects without recommendations produce no recommendation
series, rather than misleading zero values.

These metrics use the existing kube-state-metrics scrape job, without a second
scrape target. Its configuration and read-only RBAC are enabled conditionally;
a pod-template checksum triggers reload when configuration changes.

The provisioned **VPA and Goldilocks** dashboard in **Infrastructure / Monitoring**
is included when VPA is enabled. It provides namespace, workload-kind, workload
and container filters, recommendation bounds, current targets, pending VPA
inventory and exporter scrape health. Inventory panels count VPA objects and
are independent of the container filter. Values are per container, not totals
multiplied by workload replica counts.

## Interpreting recommendations

Recommendations are observations, not capacity guarantees. Wait for representative
load, including peaks and periodic tasks, before changing resources. An initial
recommendation is not evidence that a workload has been fully characterized.

Review CPU throttling, memory peaks/OOM events, application behaviour and any
horizontal autoscaler before accepting a suggestion. This repository requires
memory requests to equal memory limits; dashboard suggestions must be adapted
to that policy, not copied blindly.

Changes should be made to source constants or module inputs and deployed through
the normal workflow, never applied by manually editing live workloads. This
integration does not enable automatic tuning or publish data to Fairwinds.

Removing Goldilocks or its namespace selection may leave VPA objects and
recommendation history. Helm retains installed CRDs on uninstall. Review these
objects before any cleanup; do not delete shared VPA CRDs as an automatic rollback.

## Primary references

- [kube-state-metrics custom resource metrics](https://github.com/kubernetes/kube-state-metrics/blob/v2.19.1/docs/metrics/extend/customresourcestate-metrics.md)

- [Kubernetes VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [VPA components](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/components.md)
- [Fairwinds VPA chart](https://github.com/FairwindsOps/charts/tree/vpa-5.1.0/stable/vpa)
- [Goldilocks source and licence](https://github.com/FairwindsOps/goldilocks/tree/v4.16.2)
- [Goldilocks controller flags and health endpoint](https://github.com/FairwindsOps/goldilocks/blob/v4.16.2/cmd/controller.go)
- [Goldilocks dashboard health](https://github.com/FairwindsOps/goldilocks/blob/v4.16.2/pkg/dashboard/health.go)
- [Goldilocks namespace and update-mode selection](https://github.com/FairwindsOps/goldilocks/blob/v4.16.2/pkg/vpa/vpa.go)
