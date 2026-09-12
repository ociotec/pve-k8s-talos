# Specification: workload admission requirements

## Goal

Gradually prevent user-managed workloads from being created or updated without
explicit CPU and memory resources, or without the health probes that apply to
long-running services. The policy is disabled by default per cluster and
provides minimal, traceable, time-bound exceptions.

This specification does not change cluster state or install a policy engine.

## Policy engine decision

[Kyverno](https://kyverno.io/) is the proposed engine. It is deployed as part
of `k8s-net`, because it is a cross-cutting Kubernetes component and its
policies apply before service modules.

Kyverno observes Kubernetes admission requests and evaluates declarative rules
against manifests. For this requirement, it provides YAML-based validation,
audit and enforcement modes, policy reports, actionable errors, and a future
path to centrally managed exception resources.

Kubernetes also provides `ValidatingAdmissionPolicy`, stable since Kubernetes
1.30, which evaluates CEL expressions in the API server and can audit, warn, or
deny. It is a valid alternative for small, dependency-free rules. It is not the
initial choice because this policy spans several workload types, has
metadata-driven exceptions, and benefits from Kyverno's reporting model.

References: [Kubernetes validating admission policies](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
and [Kyverno cluster policies](https://kyverno.io/docs/policy-types/cluster-policy/).

## Per-cluster configuration

`clusters/<cluster>/k8s_net_constants.tf` configures Kyverno.

```hcl
locals {
  # Install Kyverno only to inventory policy violations, without blocking them.
  enable_kyverno_audit = false

  # Install Kyverno and deny violations of the enabled policies.
  enable_kyverno_enforce = false
}
```

Both flags default to `false`. When both are `false`, no Kyverno namespace,
CRDs, controllers, webhooks, or policies are created. With
`enable_kyverno_audit = true`, policies use `Audit` mode and do not change
admission. With `enable_kyverno_enforce = true`, policies use `Enforce`
mode and deny violations.

The flags are mutually exclusive. The implementation must fail during the
OpenTofu plan if both are `true`. Duplicating the same policy in audit and
enforce modes would create redundant results without improving visibility:
enforced policies can also scan existing resources and report violations.

The installation must not use `failurePolicy: Fail` in audit mode. In enforce
mode, a known validation failure must deny the request, but controller
availability must be tested first and any necessary system namespace exclusion
must be documented.

`clusters/<cluster>/monitoring_constants.tf` configures Policy Reporter and
its browser-facing UI:

```hcl
locals {
  # Deploy Policy Reporter, its Kyverno plugin, and its ingress-protected UI.
  enable_policy_reporter = false

  policy_reporter_hostname        = "policy-reporter.${local.domain}"
  policy_reporter_tls_secret_name = "policy-reporter-tls"

  # Policy Reporter is an operational UI and must not be exposed anonymously.
  policy_reporter_auth_keycloak_realm  = "company"
  policy_reporter_auth_allowed_groups  = ["monitoring-view", "monitoring-edit"]
  policy_reporter_auth_ca_secret_name  = "policy-reporter-oauth-ca"
}
```

When `enable_policy_reporter` is `false`, the monitoring deployment creates no
Policy Reporter resources. When enabled, it creates the Policy Reporter core,
REST API, UI, Kyverno plugin, Prometheus scrape configuration, and an HTTPS
Ingress. The backing Service remains `ClusterIP`, as is normal for an ingress
backend; the UI is deliberately exposed through ingress rather than as an
internal-only or port-forward-only service.

The monitoring TLS secret catalog must contain
`policy_reporter_tls_secret_name`, sourced from the certificate catalog in
`k8s_net_constants.tf`. The ingress must use the existing OAuth2 Proxy and
Keycloak pattern, with the listed Keycloak realm and authorized groups. The
implementation must reject an enabled public UI without TLS and authentication.

## Component ownership and dependency order

Kyverno belongs to `k8s-net`; Policy Reporter belongs to `monitoring`:

```text
k8s-net: PriorityClasses → Kyverno → workload requirement policies
monitoring: Policy Reporter core + Kyverno plugin + UI → HTTPS Ingress
```

Kyverno does not depend on cert-manager, MetalLB, ingress-nginx, or Policy
Reporter. It requires only a functioning Kubernetes API, pod scheduling, and
cluster service networking. It may therefore be installed early in `k8s-net`.

Policy Reporter requires Kyverno's report CRDs and the reports created by
Kyverno. Its public UI also requires ingress-nginx; TLS requires the configured
certificate source, and Keycloak-backed authentication requires the identity
section to be available. The monitoring module must make these dependencies
explicit. Policy Reporter must not be a dependency of Kyverno admission.

## Controller placement and sizing

The admission controller runs only on workers: it has no control-plane
tolerations or control-plane affinity. It uses at least two replicas spread by node
hostname, `priorityClassName: infra-high`, explicit resources, health probes,
and a PodDisruptionBudget.

`infra-high` is appropriate for an infrastructure controller. In fail-closed
mode, its unavailability can block matching API changes, but it does not
interrupt workloads already running. `infra-critical` remains reserved for
data-plane services whose absence directly breaks their dependents.

The reports controller is not in the admission path. It may run as one initial
replica with `priorityClassName: infra-observability`. The first
implementation uses only the admission and reports controllers; it disables the
background and cleanup controllers because validation-only policies do not
require them.

### Initial resource budgets

The following initial sizing assumes two admission-controller replicas on
different workers, simple resource/probe validation rules, and a single reports
controller. It is intentionally a starting budget and must be reviewed with
Kyverno metrics after rollout.

| Mode | Component | Replicas | CPU request / limit per replica | Memory request / limit per replica |
| --- | --- | ---: | --- | --- |
| Audit | Admission controller | 2 | `250m` / `1` | `512Mi` / `512Mi` |
| Audit | Reports controller | 1 | `150m` / `500m` | `256Mi` / `256Mi` |
| Enforce | Admission controller | 2 | `500m` / `1` | `768Mi` / `768Mi` |
| Enforce | Reports controller | 1 | `200m` / `500m` | `384Mi` / `384Mi` |

Total requested resources are `650m` CPU and `1280Mi` memory in audit mode,
and `1200m` CPU and `1920Mi` memory in enforce mode. Memory requests equal
limits, as required by repository policy. The additional enforce-mode headroom
protects admission latency and availability; the rule evaluation itself is not
expected to be materially more expensive than audit mode.

Policy Reporter is not in the admission path. Its implementation must define
CPU and memory requests/limits, probes, `infra-observability` priority, and a
PodDisruptionBudget for every enabled component. Size it separately from
Kyverno after observing report volume and UI/API use.

## Validation scope

Policies run on `CREATE` and `UPDATE` for the following resources:

| Requirement | Included resources | Included containers |
| --- | --- | --- |
| CPU and memory resources | Deployment, StatefulSet, DaemonSet, Job, CronJob | `containers` and `initContainers` |
| `readinessProbe` and `livenessProbe` | Deployment, StatefulSet, DaemonSet | Regular `containers` only |

For a `CronJob`, resources are inspected under
`.spec.jobTemplate.spec.template.spec`; other resources are inspected in their
pod template. `ephemeralContainers` are excluded.

Jobs and CronJobs are excluded from the probe policy: their execution is
finite, they do not provide a stable endpoint for traffic, and Kubernetes does
not run readiness, liveness, or startup probes for init containers.

The first version does not validate directly created `Pod` objects. Exception
annotations live on the controller resource and are not necessarily propagated
to generated Pods. A direct-Pod policy needs its own exception model first.

## Resource rule

Every included container must declare all of the following together:

```yaml
resources:
  requests:
    cpu: <quantity>
    memory: <quantity>
  limits:
    cpu: <quantity>
    memory: <quantity>
```

A `LimitRange` may still set namespace defaults and limits, but it does not
replace this rule: each manifest must explicitly declare its reservation and
ceiling.

## Probe rule

Every regular container in a Deployment, StatefulSet, or DaemonSet must declare:

```yaml
readinessProbe: { ... }
livenessProbe: { ... }
```

`startupProbe` is not mandatory in the first version. It is recommended for
legitimately slow starts, including migrations, WAL recovery, JVM startup, and
storage recovery. Each probe endpoint must be verified against official
component documentation or existing configuration; do not guess endpoints.

## Temporary annotation-based exceptions

Two independent exceptions are allowed. They apply to controller resource
`metadata.annotations`, never to the pod template:

```yaml
metadata:
  annotations:
    policy.pve-k8s-talos.io/allow-missing-resources: "true"
    policy.pve-k8s-talos.io/allow-missing-probes: "true"
    policy.pve-k8s-talos.io/exception-reason: "The component has no health endpoint"
    policy.pve-k8s-talos.io/exception-owner: "platform"
    policy.pve-k8s-talos.io/exception-expires: "2027-03-31"
```

- `allow-missing-resources` skips only the rule requiring all four CPU/memory
  fields. Per-field exceptions are not supported.
- `allow-missing-probes` skips only readiness and liveness; it does not affect
  resource validation.
- When either exception is present, `exception-reason`, `exception-owner`,
  and `exception-expires` are mandatory.
- The expiry date uses `YYYY-MM-DD`, must not be expired, and has a proposed
  maximum validity of 90 days.
- Any value other than the literal string `"true"` is invalid.

An exception must not become a self-authorization mechanism. The policy permits
these annotations only for explicitly configured, RBAC-authorized administrative
identities or groups. It rejects unauthorized attempts to add, modify, or renew
an exception. Active and near-expiry exceptions must be exposed through Kyverno
reports and monitoring metrics or alerts.

Namespace-wide exemptions must not be the normal mechanism. If a system
exclusion is necessary to bootstrap the engine, it must be minimal and
documented.

## Adoption plan

1. Enable `enable_kyverno_audit = true` in a non-critical cluster.
2. Inventory violations with Kyverno reports and repository audit scripts.
3. Fix manifests and create justified, owner-assigned, expiring exceptions only
   where necessary.
4. Verify CI/CD, Helm, and installed operators while audit remains enabled.
5. Disable audit and enable `enable_kyverno_enforce = true` first in selected
   namespaces, then across the remaining application namespaces.
6. Periodically review and remove exceptions as workloads are corrected.

Policy Reporter may be enabled after Kyverno audit reports are available. Its
ingress is deployed only after the required ingress, TLS, and authentication
dependencies are ready. It is not required to start audit mode, and a Policy
Reporter outage must never affect Kyverno admission.

Before enforce mode, explicitly test updates to existing workloads. An update
must comply with the rule or carry a valid exception, so an operational change
is not unexpectedly blocked by historical debt.

## Future implementation acceptance criteria

- With both flags disabled, Kyverno and all of its resources are absent.
- Both flags enabled is rejected during planning.
- Policies cover every resource type and template path listed here.
- A container missing any of the four resource values violates the rule unless
  it has a valid resource exception.
- A service container missing either probe violates the rule unless it has a
  valid probe exception.
- Jobs and CronJobs do not violate the policy for missing readiness/liveness.
- Unauthorized, incomplete, or expired exceptions are denied in enforce mode
  and visible in audit mode.
- Error messages identify the requirement, container, and applicable exception.
- With Policy Reporter disabled, monitoring creates none of its resources.
- With Policy Reporter enabled, its UI is exposed only through authenticated
  HTTPS ingress and shows Kyverno report results.
- A Policy Reporter failure does not delay or alter a Kyverno admission result.

## Future validation and deployment

When implemented, validate the generated `k8s-net` and `monitoring` workspaces
from the cluster directory. The minimum command that deploys both sections, run
by the operator from `clusters/<cluster>`, is:

```sh
../../scripts/deploy.sh --services-only --skip-ceph --skip-identity --skip-s3-storage --skip-platform --skip-kafka --skip-benchmark
```

Do not run this deployment until the cluster and both `k8s-net` and `monitoring`
sections have been explicitly authorized.
