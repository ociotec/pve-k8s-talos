# Automatic worker resource reservations

Status: Specification

Protect Talos and Kubernetes node services by calculating worker reservations
from declared VM memory and configured pod density. Existing deployments adopt
the defaults on their next authorized Talos deployment, without constants changes.

## Scope

```text
Worker VM capacity
  |
  +-- systemReserved -------- Talos services, system runtime and kernel
  +-- kubeReserved ---------- kubelet and pod runtime
  +-- memory eviction margin
  |
  `-- Allocatable ----------- infrastructure pods + application pods
```

Infrastructure running as pods uses its own requests and must not be counted
again in host reservations. Application requests and limits remain unchanged.
The shared-headroom DaemonSet is outside this scope.

Control planes host Kubernetes control components and Talos services, and can
also host infrastructure DaemonSets even without application workloads. Keep
their existing sizing and kubelet configuration unchanged in this phase.
Their host reservations require separate accounting for etcd and control-plane
pods to avoid double counting.

## Default formulas

Let `P` be effective `talos.max_pods` (110 when absent or empty), `M` declared
worker memory in MiB, and `C` declared vCPUs. Use configured maximum pods rather
than current occupancy. `up(x, s) = ceil(x / s) * s`.

```text
All CPU results below are millicores; all memory results are MiB.

System CPU       = 250
System memory    = max(512, up(0.01 * M, 256))

Kubernetes CPU   = up(250 + 2 * P, 50)
Kubernetes memory= up(256 + 5 * P, 256)

Eviction memory  = min(2048, max(512, up(0.01 * M, 256)))

Estimated allocatable CPU    = 1000 * C - System CPU - Kubernetes CPU
Estimated allocatable memory = M - System memory - Kubernetes memory
                                - Eviction memory
```

These coefficients are engineering heuristics, not upstream sizing guarantees.
Pod count approximates management work; sidecars, churn, image operations and
kernel activity can change actual needs. CPU capacity validates fit rather than
multiplying the service budgets. Larger RAM increases the kernel allowance.
Live Kubernetes Capacity can differ from declared VM memory; verify Allocatable
against live Capacity and effective settings after deployment.

For 32 vCPUs, 64 GiB and 250 maximum pods:

```text
                    CPU             RAM
VM capacity         32              64 GiB
System reservation   0.25            0.75 GiB
Kubernetes reserve   0.75            1.50 GiB
Eviction margin      -               0.75 GiB
------------------------------------------------
Estimated pods      31              61 GiB
```

## Protection behavior

```text
Reduced Allocatable -> fewer pod requests fit
Pods approach aggregate memory budget -> kubelet can evict pods
Node available memory falls below hard threshold -> pressure eviction
Memory grows faster than recovery -> kernel OOM remains possible
```

Set `enforceNodeAllocatable: [pods]`. Do not add `system-reserved` or
`kube-reserved`, or configure their enforcing cgroups. The budgets reduce
capacity available to pods without imposing matching hard ceilings on host
services. They do not pin CPUs, provide exclusive physical cores, or guarantee
capacity on an overloaded Proxmox host. Preserve Talos internal cgroup behavior.

Set the calculated memory threshold in `evictionHard.memory.available`.
Preserve effective disk and inode thresholds and existing soft eviction settings.
Pressure eviction (`Evicted`) differs from a container exceeding its memory
limit (`OOMKilled`). Neither these budgets nor eviction eliminate OOM risk.

## Configuration and integration

```text
VM resource profile + effective max_pods + shared defaults
                         |
                  one sizing calculation
                         |
              +----------+-----------+
              |                      |
       generation report      Talos worker patches
                                     |
                      legacy or native version contract
```

- Calculate per worker resource profile; use one implementation for reporting,
  validation and generated values.
- Render through the source machine template and generation flow. Preserve
  existing mounts, max-pods arguments and Talos version compatibility.
- Generated values replace the CPU/memory fields in `systemReserved` and
  `kubeReserved`; they are totals, not additions to Talos defaults.
- Preserve effective PID and ephemeral-storage reservations. A nonempty
  `systemReserved` map can suppress Talos defaults; materialize preserved fields
  explicitly when required by the supported Talos version.
- Existing custom CPU/memory reservations or memory eviction settings must be
  detected and compared. Identical values pass; conflicting custom values stop
  preflight with a field-specific explanation before mutation. Resolve them in
  their source configuration, never by silently stacking or overwriting patches.
- Print calculated budgets, projected Allocatable and any conflicts without
  credentials. Reject invalid inputs or nonpositive projected CPU/memory.
  Warn when current pod requests exceed projected Allocatable. Never shrink
  reservations automatically to fit a small worker.
- Emit canonical Kubernetes quantities, including whole cores and whole GiB.

Shared defaults need no opt-in. During implementation, document only these
optional formula controls as commented examples under `talos` in
`clusters/sample/constants.auto.tfvars`; existing cluster files need no edits:

| Optional control | Default |
| --- | --- |
| `worker_system_reserved_cpu` | `250m` |
| `worker_system_reserved_memory_min` | `512Mi` |
| `worker_system_reserved_memory_percent` | `1` |
| `worker_kube_reserved_cpu_per_pod_millicores` | `2` |
| `worker_kube_reserved_memory_per_pod_mib` | `5` |
| `worker_eviction_memory_min` | `512Mi` |
| `worker_eviction_memory_percent` | `1` |
| `worker_eviction_memory_max` | `2Gi` |

Keep the Kubernetes fixed bases and rounding steps internal. Validate override
units, finite positive values and eviction minimum/maximum consistency.

## Validation and rollout

```text
Generate and validate
        |
Inspect live configuration and projected capacity
        |
One worker in a small environment
        |
Verify effective configuration, Ready and Allocatable
        |
Remaining workers -> medium environment
        |
Review historical usage -> revise shared coefficients if needed
```

Activation requires the normal, explicitly authorized deployment path. The
implementation must support a controlled first-worker rollout before changing
the remaining workers; generation alone must not apply configuration.

Verify formula boundaries, heterogeneous profiles, 110/250/500 pod settings,
canonical quantities, conflicting patches and preserved defaults. Follow the
repository validation requirements for affected generated workspaces.

Accept when reservations and eviction maps match the calculation, workers stay
Ready, infrastructure remains healthy, and no unexplained Pending pods, OOMs or
pressure evictions appear during startup and representative workload churn.
Record before/after settings for rollback through the same deployment flow.
After a representative observation period, review host-service CPU, memory peaks,
pod density, churn and pressure events before revising the heuristics.

## References

- [Kubernetes node reservations](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Kubernetes node pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Talos kubelet configuration defaults](https://github.com/siderolabs/talos/blob/v1.13.0/internal/app/machined/pkg/controllers/k8s/kubelet_spec.go)
