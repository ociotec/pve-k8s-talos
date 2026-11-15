# Worker CPU and memory headroom

Status: Specified; implementation pending. Finalize rounding before implementation.
No reservation workload is deployed by this specification.

## Goal

Keep part of each worker's schedulable CPU and memory available for existing
workloads to grow beyond their requests, while restricting new pod placements.
Calculate and configure the two resource budgets independently.

```text
Worker CPU and memory
  |
  +-- Talos / Kubernetes reservations
  +-- Memory eviction margin
  |
  `-- Allocatable
        +-- Workload requests
        +-- Headroom pod requests --- minimal actual CPU and memory use
        `-- Remaining scheduling capacity

Existing pods may use idle CPU and available memory, within their limits.
New placements must fit alongside both headroom requests.
```

This complements [worker resource reservations](worker-resource-reservations.md).
It does not replace host protection, resource limits, pressure eviction or
capacity planning. Workloads whose request already equals their limit for a
resource have no additional growth allowance for that resource.

## Scope

- Target workers only; exclude control planes.
- Adopt shared defaults without adding constants to every existing cluster.
- Support independent CPU and memory percentages and an explicit whole-component
  opt-out. Zero percentages retain the operating minimums; disabling the component
  removes its pods entirely. Express exclusions through cluster configuration,
  never shared name checks.
- Keep application requests, limits and priorities unchanged.
- Configure overrides under `k8s` in `constants.auto.tfvars` and deploy through
  the existing `k8s-net` section using `--services-only`; no new section is needed.
- A headroom-only deployment must not reconcile VM or Talos configuration, enter
  node maintenance, drain workers, or restart node/control-plane services.

## Reservation workload

Run one minimal `pause` pod on each eligible worker through a DaemonSet-based
deployment. Its CPU and memory requests occupy scheduling capacity without
consuming the requested CPU or allocating the requested memory.

```text
Higher priority    Kubernetes / storage / essential services
                  infra-headroom
Lower priority    Monitoring / ordinary applications / benchmarks
```

Use the existing `infra-headroom` PriorityClass with `PreemptLowerPriority`.
The scheduler may preempt lower-priority application and infrastructure pods to
establish or enlarge the reservation. It cannot preempt equal- or higher-priority
pods. Higher-priority workloads may in turn preempt headroom. Do not move ordinary
infrastructure into this class.

Ensure the PriorityClass exists before creating headroom workloads, including
on a new cluster. Keep `infra-headroom` owned by `k8s-net/main.tf` and establish
an explicit dependency from the DaemonSet to that existing class. No class
ownership transfer or additional workspace is required.

Define CPU and memory requests and limits, with equal memory request and limit,
using shared implementation defaults. The CPU request represents intentional
scheduling headroom, not measured pause consumption; its limit must support that
request. Use a pinned image and repository ownership labels. Do not generate CPU
load, allocate memory artificially or request persistent storage.

The pause container has no service health endpoint. Document a narrowly scoped
probe-policy exception rather than inventing probes; use container state and
DaemonSet readiness to detect failures.

## Sizing and configuration

Calculate CPU and memory requests separately from each worker's Kubernetes
Allocatable, after host reservations and the memory eviction margin. For each
resource, use the larger of its configured operating minimum and its independently
configured percentage of Allocatable. Do not add the minimum on top of the
percentage result or derive one resource budget from the other.

Keep input variables, percentages, minimums and rounding controls independent.
CPU limits must be at least the calculated request and the CPU operating limit
floor. Memory limits equal calculated memory requests. Review rounding separately
for CPU and memory and emit canonical Kubernetes quantities.

Support heterogeneous workers and reject invalid inputs or a reservation that
leaves no usable scheduling capacity. Zero percentages must still produce the
pause container's operating resources, with all required requests and limits.
Small nonzero percentages must never produce values below those minimums.

A DaemonSet has a shared pod resource template. When calculated reservations
differ between workers, the implementation must account for both resource values
explicitly, for example through disjoint sizing groups. Use one combined headroom
pod per eligible worker, not a separate pod for each resource. Never overlap
reservation pods during group or profile changes.

Keep formulas, coefficients, bounds, rounding and defaults authoritative in the
implementation. This document does not duplicate them. Once implemented, link
the calculation source here.

Document only significant overrides as commented examples under `k8s` in
`clusters/sample/constants.auto.tfvars`. Examples must use clearly identified
alternative values, not copies of defaults. Existing cluster constants need no
edits unless opting out or overriding shared behavior. Shared defaults establish
only residual operating requests until additional percentage headroom is enabled.

## Capacity and activation

```text
Read-only per-worker fit report
          |
Validate reservation and report potential displacement
          |
Explicitly authorized Kubernetes-only apply
          |
Scheduler places headroom, preempting lower-priority pods if needed
          |
Verify coverage and report affected / Pending workloads
```

Check CPU and memory fit separately per worker against live Allocatable and
scheduler-effective requests, including init containers, pod overhead and the
headroom pod's own pod slot. Report the calculated budget and remaining capacity
for each resource. Spare CPU cannot compensate for a memory deficit, or vice
versa; cluster-wide spare capacity cannot compensate for a worker deficit.
Explain other scheduling blockers such as taints, selectors and pod-count limits.

Reject invalid or impossible reservation settings before activation. Report
existing request deficits and estimate which priority groups may be displaced;
a deficit recoverable through lower-priority preemption must not block activation.
Scheduling remains the final authority. If equal- or higher-priority requests or
other constraints prevent placement, headroom can remain Pending and deployment
validation must report incomplete coverage. Do not silently reduce the reservation
or lower workload requests to make it fit.

Preempted workloads may restart elsewhere or remain Pending. PodDisruptionBudgets
are not a strict protection against scheduler preemption. These interruptions are
an accepted consequence of establishing the reservation, not an instruction to
drain workers or explicitly roll out unrelated workloads.

Changes to reservation size replace only the affected headroom pods and may
trigger scheduler preemption. Avoid overlapping reservation pods and expose
incomplete coverage during replacement. Unchanged configuration must be a no-op.

Keep headroom resources separate from VM/Talos reconciliation and reuse the normal
deployment authorization and state synchronization paths. Applying headroom alone
must not certify unrelated VM/Talos changes as deployed.

## Guarantees and limits

Requests reserve scheduler accounting, not dedicated physical resources. Existing
pods are not individually entitled to either margin.

| Resource | Intended benefit | Remaining limits |
| --- | --- | --- |
| CPU | Leave room for bursts and reduce competition from new placements. | No exclusive cores or latency guarantee. Simultaneous bursts still compete, and CPU limits can throttle workloads despite idle capacity. |
| Memory | Leave room for growth beyond workload requests. | No dedicated pages. Simultaneous growth can still exhaust memory; kernel OOM and kubelet pressure eviction remain possible. |

Scheduling uses declared requests rather than current usage. Headroom can limit
further concentration, but does not guarantee balanced runtime utilization or
redistribute existing pods. Do not lower application requests automatically to
make room; undersized requests hide demand, and CPU requests also determine
relative CPU shares during contention. Priority does not establish runtime CPU
or memory isolation.

Higher-priority scheduling may consume the margin by displacing the pause pod.
Report missing or Pending headroom as reduced coverage rather than claiming the
worker remains protected. To run all intended workloads alongside headroom,
capacity must accommodate both; otherwise increase capacity or reduce workloads.
Successful headroom placement alone does not prove application capacity is adequate.

Removing or disabling the feature deletes only its reservation workloads and
releases their scheduling requests. Retain the shared PriorityClass. Reuse the
normal deployment and state synchronization paths for activation and rollback.

## Acceptance

- Finalize resource-specific rounding before implementation. CPU and memory
  controls remain independent, with no duplicated defaults in this specification
  or sample.
- Every eligible worker has exactly one Running, Ready headroom pod with the
  expected CPU and memory requests. Zero percentages retain operating minimums;
  disabling the component removes headroom pods entirely.
- Actual priority and preemption behavior match the design. Headroom can displace
  lower-priority workloads, but cannot preempt equal- or higher-priority pods.
- Heterogeneous sizes, small workers, node additions, profile changes and opt-out
  preserve coverage and never create duplicate reservations.
- Capacity and scheduling failures are actionable. Incomplete coverage fails
  validation without silently changing the requested budget. Report workloads
  displaced or left Pending even when headroom placement succeeds.
- Controlled tests independently demonstrate CPU bursts and memory growth within
  workload limits, while new placements are constrained by the corresponding
  reservation requests. Verify residual-only, CPU-only, memory-only and combined
  operation, including percentage results below the operating minimums.
- Validation records before/after scheduling capacity, pod identities and restarts,
  requested headroom and actual pause consumption, CPU saturation, throttling,
  service latency, preemption, memory pressure events and OOMs.
- Headroom-only changes never apply VM/Talos changes or restart node/control-plane
  services. They may replace pause pods and cause lower-priority preemption only.
- Reapplying unchanged configuration does not restart workloads. Disabling the
  feature restores scheduling capacity without changing host reservations.
- Review historical usage after a representative observation period before
  revising the shared sizing assumptions.
