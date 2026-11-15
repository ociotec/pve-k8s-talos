# Worker CPU and memory headroom

Status: Draft. Review sizing formulas before implementation. No reservation
workload is deployed by this specification.

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
- Support independent cluster opt-outs for CPU and memory, and disabling both.
  Keep memory headroom excluded from the designated CI/CD environment; its CPU
  policy is a separate decision. Express exclusions through cluster configuration,
  never shared name checks.
- Keep application requests, limits and priorities unchanged.
- Integrate into the existing `k8s-net` section and deployment flow; no new section
  or worker restart is required.

## Reservation workload

Run one minimal `pause` pod on each eligible worker through a DaemonSet-based
deployment. Its CPU and memory requests occupy scheduling capacity without
consuming the requested CPU or allocating the requested memory.

```text
Higher priority    Kubernetes / storage / essential services
                  infra-headroom
Lower priority    Monitoring / ordinary applications / benchmarks
```

Use the existing `infra-headroom` PriorityClass. Configure it to prevent headroom
pods from preempting other pods; its current preemption behavior must be updated
as part of implementation. Higher-priority workloads may still preempt headroom.
Do not move ordinary infrastructure into this class.

Define CPU and memory requests and limits, with equal memory request and limit,
using shared implementation defaults. The CPU request represents intentional
scheduling headroom, not measured pause consumption; its limit must support that
request. Use a pinned image and repository ownership labels. Do not generate CPU
load, allocate memory artificially or request persistent storage.

The pause container has no service health endpoint. Document a narrowly scoped
probe-policy exception rather than inventing probes; use container state and
DaemonSet readiness to detect failures.

## Sizing and configuration

Calculate CPU and memory reservations automatically through separate formulas,
each with its own input variables, coefficients, bounds, rounding and overrides.
Do not derive one resource budget from the other or couple their tuning controls.
Review the relevance of declared vCPUs, memory, pod density and existing node
reservations separately for each calculation. Select the formulas in the pending
sizing review; do not assume both resources need the same proportional margin.

Support heterogeneous workers and reject invalid inputs or a reservation that
leaves no usable scheduling capacity for an enabled resource. Account for the
pause container's minimal operating resources when either headroom budget is
disabled; disabling a budget must not remove required requests or limits.

A DaemonSet has a shared pod resource template. When calculated reservations
differ between workers, the implementation must account for both resource values
explicitly, for example through disjoint sizing groups. Use one combined headroom
pod per eligible worker, not a separate pod for each resource. Never overlap
reservation pods during group or profile changes.

Keep formulas, coefficients, bounds, rounding and defaults authoritative in the
implementation. This document does not duplicate them. Once implemented, link
the calculation source here.

Document only significant overrides as commented examples in the relevant
sample constants file. Examples must use clearly identified alternative values,
not copies of defaults. Existing cluster constants need no edits unless opting
out or overriding shared behavior.

## Capacity and activation

```text
Read-only per-worker fit report
          |
Enough CPU and memory for workloads + headroom?
          |
     +----+----+
    yes       no
     |         `-- Report deficit; increase capacity or reduce workloads
     v
Explicitly authorized pilot
          |
Verify coverage, requests, priorities and workload stability
          |
Broader explicitly authorized rollout
```

Check CPU and memory fit separately per worker against live Allocatable and
scheduler-effective requests, including init containers, pod overhead and the
headroom pod's own pod slot. Report the calculated budget and remaining capacity
for each resource. Spare CPU cannot compensate for a memory deficit, or vice
versa; cluster-wide spare capacity cannot compensate for a worker deficit.
Explain other scheduling blockers such as taints, selectors and pod-count limits.

Insufficient capacity fails preflight before activation. Scheduling remains the
final authority: if capacity changes after preflight, the headroom pod stays
Pending without preempting workloads, and deployment validation reports incomplete
coverage. Do not silently reduce the calculated reservation to make it fit.

Existing pods are not automatically rebalanced. Do not drain workers or restart
applications to activate this feature. Changes to headroom size must avoid
overlapping reservation pods and expose incomplete coverage during replacement.

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
worker remains protected. Capacity must accommodate the intended workloads and
headroom together; preemption is not a substitute for sizing.

Removing or disabling the feature deletes only its reservation workloads and
releases their scheduling requests. Retain the shared PriorityClass. Reuse the
normal deployment and state synchronization paths for activation and rollback.

## Acceptance

- Review both formulas before implementation begins. CPU and memory controls
  remain independent, with no duplicated defaults in this specification or sample.
- Every eligible worker has exactly one Running, Ready headroom pod with the
  expected CPU and memory requests. A disabled resource retains only the pause
  container's operating budget; workers excluded from both have no headroom pod.
- Actual priority and non-preempting behavior match the design. No workload is
  preempted by a headroom pod, including on a full worker.
- Heterogeneous sizes, small workers, node additions, profile changes and opt-out
  preserve coverage and never create duplicate reservations.
- Fit failures are actionable; capacity races leave Pending reservations and a
  failed coverage check, without silently changing the requested budget.
- Controlled tests independently demonstrate CPU bursts and memory growth within
  workload limits, while new placements are constrained by the corresponding
  reservation requests. Verify CPU-only, memory-only and combined operation.
- The pilot records before/after scheduling capacity, pod identities and restarts,
  requested headroom and actual pause consumption, CPU saturation, throttling,
  service latency, memory pressure events and OOMs. Investigate regressions before
  expanding the rollout.
- Reapplying unchanged configuration does not restart workloads. Disabling the
  feature restores scheduling capacity without changing host reservations.
- Review historical usage after a representative observation period before
  revising the shared sizing assumptions.
