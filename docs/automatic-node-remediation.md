# Automatic Node Remediation and Stateful Workload Recovery

Status: Initial pilot implementation

## Purpose

Provide automatic and safe recovery of Kubernetes workloads when a worker node
becomes unreachable, including workloads using CSI-backed exclusive volumes.
Proxmox VE and Ceph RBD are the initial execution and storage backends, not
coordinator dependencies.

The solution must recover services without human intervention while preventing
two nodes from writing to the same block volume. It should also recover and
return the failed worker to service when possible.

## Problem

Kubernetes cannot determine whether an unreachable node is powered off or is
still running with access to its storage. Automatically moving an exclusive
volume without first isolating its old writer could create two writers and
corrupt data.

Storage replication alone does not prove that the previous volume user has
stopped writing.

## Goals

- Detect an unhealthy worker automatically.
- Fence the worker before releasing its exclusive volumes.
- Recover affected workloads on healthy workers.
- Recover and safely reintegrate the failed worker.
- Fail safely when isolation cannot be proven.
- Prevent a shared infrastructure failure from triggering mass remediation.
- Support different compute platforms through execution-fencing adapters.
- Support different CSI backends through storage-specific fencing adapters.

## Non-goals

- Database-level replication or promotion.
- Automatic remediation of control-plane nodes in the initial scope.
- Guaranteed recovery when Kubernetes, compute, and storage control paths are
  all unavailable.
- Returning recovered workloads to their original node.

## Architecture

The portable target is a coordinator outside the Kubernetes cluster it
protects. The initial implementation runs two leader-elected replicas on
control-plane nodes. This covers worker failures without introducing a new
external runtime; the fencing interfaces remain separable from Kubernetes.

```text
                      +-----------------------+
                      | Remediation           |
                      | coordinator           |
                      +----+---------+--------+
                           |         |
              node state   |         | fencing requests
              and taints   |         |
                           v         v
                    +-------------+  +--------------+
                    | Kubernetes  |  | Compute and  |
                    | API         |  | storage APIs |
                    +------+------+  +-------+------+
                           |                |
                           | scheduling     | isolate execution
                           |                | and storage
                           v                v
                      +-----------------------+
                      | Worker and its        |
                      | stateful workloads    |
                      +-----------------------+
```

The coordinator owns the remediation workflow. Kubernetes remains responsible
for scheduling replacement pods, while the compute and storage backends provide
independent ways to isolate the old writer.

### Implementation Status

This document describes both the portable target and the initial pilot. The
following distinction prevents planned behavior from being mistaken for an
implemented guarantee.

| Capability | Pilot | Portable target |
| --- | --- | --- |
| Coordinator runtime | Two leader-elected pods on control-plane nodes | May run outside the protected cluster |
| Compute fencing | PVE VM status, stop, and start | Pluggable compute or hardware adapters |
| Storage fencing | Ceph RBD through CSI-Addons `NetworkFence` | Per-CSI-driver adapters |
| Safe-path fallback | Execution fencing is required before storage release | Either independently verified execution or complete storage fencing |
| Workload health | Kubernetes reschedules pods; application readiness is not inspected by the controller | Optional workload-aware recovery gates |

### Initial Controller Packaging and Access

The pilot does not build a dedicated application image. It runs the
repository-managed Python controller on `python:3.13-alpine`; OpenTofu places
the script and non-secret node mapping in a ConfigMap and mounts them read-only
in two leader-elected controller pods. Only the leader performs remediation.

```text
ConfigMap: controller.py + node -> PVE host/VMID/IP mapping
                         |
                         v
              python:3.13-alpine pods
                   leader + standby
```

A future production image should embed the controller, carry an explicit
version, and be pinned by digest. This improves provenance and vulnerability
tracking without changing the remediation protocol.

PVE connection values enter through the cluster deployment environment and are
materialized as a Kubernetes Secret. The pod receives the API endpoint, token,
and TLS verification mode as environment variables. The token is sent to PVE
as `PVEAPIToken` authentication over HTTPS; the deployment first verifies that
it has the required permissions for every managed worker VM.

```text
Cluster deployment environment
  PVE endpoint + API token + TLS mode
                  |
                  v
       Kubernetes Secret in kube-system
                  |
                  v
        Controller ---- HTTPS ----> PVE API
                     status/stop/start
```

The controller does not receive the VM's bridge, VLAN, MAC, or complete PVE
network configuration. It only needs network reachability to the PVE API and a
mapping from each Kubernetes worker to its PVE host and VMID. Storage-fencing
addresses are separate inputs used by the CSI adapter.

The Kubernetes Secret and OpenTofu state both contain sensitive token material
and must be protected accordingly. Prometheus has no control role: it only
scrapes the controller's `/metrics` endpoint; decisions are based directly on
Kubernetes node and Lease state.

## Safety Invariant

An exclusive volume must not be released until isolation is positively
confirmed through execution fencing or complete storage fencing:

```text
     Compute instance is confirmed isolated
                            OR
 every affected writable volume is confirmed fenced
                             |
                             v
          Workload recovery is allowed
```

If neither mechanism can confirm isolation, remediation remains pending and is
retried. The system must not trade data integrity for availability.

## Remediation Flow

```text
Node becomes unreachable
          |
          v
Detection threshold expires
          |
          v
Quarantine node (NoSchedule)
          |
          v
Attempt execution and storage fencing
          |
          +---- no fence confirmed ----> Retry and alert
          |
          v
Mark node out-of-service
          |
          v
Detach volumes and recreate pods
          |
          v
Kubernetes schedules replacement pods
(application readiness is not inspected)
          |
          v
Recover failed worker
          |
          v
Verify new boot and stable health
          |
          v
Unfence storage; remove quarantine
          |
          v
Node returns to schedulable service
```

### Detection

A node is a remediation candidate when its Kubernetes Lease remains stale
beyond a configured threshold. Detection includes these circuit breakers:

- Remediate workers only.
- Require a healthy Kubernetes control plane.
- Limit the number of simultaneous unhealthy nodes.
- Pause during declared maintenance.
- Rate-limit repeated remediation attempts.

The detector should watch Kubernetes node state directly. Monitoring alerts are
useful for visibility but should not be the control signal.

The initial fast local-network profile evaluates every 5 seconds, suspects a
node after a 20-second stale Lease, and waits another 5 seconds before fencing.

| Setting | Default | Purpose |
| --- | ---: | --- |
| Evaluation interval | 5 s | Recheck node and remediation state. |
| Stale Lease threshold | 20 s | Start suspecting an unreachable node. |
| Confirmation window | 5 s | Reject a short transient before fencing. |
| Execution-fence timeout | 45 s | Maximum wait for confirmed VM shutdown. |
| Storage-fence timeout | 60 s | Report slow fencing; it does not delay a successful result. |
| Recovery stability | 30 s | Require stable `Ready` before unfencing. |
| Per-node cooldown | 10 min | Prevent repeated remediation loops. |
| Concurrent remediations | 1 | Prevent mass fencing. |

### Remediation Inhibitors

The pilot does not begin or advance remediation when doing so would violate a
safety gate:

| Gate | Result |
| --- | --- |
| Insufficient healthy control-plane nodes | Do not begin or advance fencing. |
| Maximum concurrent remediations reached | Leave additional workers pending. |
| Worker is new, in cooldown, or explicitly disabled | Do not begin remediation. |
| PVE cannot confirm VM shutdown | Remain in fencing, do not release storage, and retry. |
| RBD attachment remains or `NetworkFence` is unconfirmed | Keep the VM stopped and retry. |

### Fencing

The initial PVE and Ceph RBD implementation performs both mechanisms in order:

1. **Execution fencing:** use the compute adapter to isolate the worker and
   verify that it can no longer execute workloads.
2. **Storage fencing:** use the adapter for each affected CSI driver to revoke
   the worker's access to its writable volumes.

The node is marked out of service only after PVE confirms that its VM is
stopped. A VM with an affected RBD attachment remains stopped until the
attachment is gone and CSI-Addons reports a successful `NetworkFence`.

### Compute Backend Portability

The coordinator maps each Kubernetes node to a compute instance and delegates
fencing and recovery to an execution adapter.

```text
ExecutionFencer
  +-- Proxmox VE adapter (initial implementation)
  +-- VM or cloud instance adapter
  +-- IPMI / Redfish adapter
  `-- Unsupported backend -> require complete storage fencing
```

An execution adapter must verify isolation, not merely accept a stop request.
Recovery may restart the same machine, relocate it, replace the instance, or
power-cycle a physical host.

### Storage Backend Portability

The coordinator identifies each backend from the CSI driver recorded on the
persistent volume and delegates fencing to a driver-specific adapter.

```text
StorageFencer
  +-- Ceph RBD adapter (initial implementation)
  +-- Future CSI adapter
  `-- Unsupported backend -> require execution fencing
```

An adapter must report a verifiable fencing result; starting a detach is not
enough. Shared or local storage may require execution fencing or
application-level replication instead of volume relocation.

### Workload Recovery

After fencing, the coordinator marks the node out of service. Kubernetes can
then remove stale pods and volume attachments and recreate the workloads on
healthy workers.

The pilot does not discover affected applications or wait for their readiness
probes. Its recovery gate is infrastructure-level: the stale RBD attachment is
gone and, when required, CSI-Addons confirms storage fencing. Application
readiness remains observable through Kubernetes and monitoring, but does not
currently block worker recovery.

### Worker Recovery

Once stale volume use is safely excluded, the coordinator recovers the worker:

1. Ask the execution adapter to restart, relocate, replace, or power-cycle the
   worker as appropriate.
2. Verify a complete stop/start power cycle through the execution adapter.
3. Require the node to remain healthy for a stabilization period.
4. Remove the out-of-service state and wait for storage unfencing.
5. Remove quarantine and make the node schedulable.

A separate quarantine prevents workloads from reaching the node while storage
unfencing is still in progress.

### Per-node Cooldown

After recovery and storage unfencing complete, the controller removes
quarantine and starts the default 10-minute cooldown. During this state the
worker is operational, schedulable, and equivalent to `Healthy` for workloads.
Only a new automatic remediation of that same worker is suppressed.

```text
Reintegrated worker
       |
       v
Cooldown: 10 min
  +-- Ready and schedulable
  +-- storage unfenced
  `-- repeat remediation suppressed
       |
       v
Healthy: repeat remediation enabled
```

Consequently, another genuine failure of the same worker during the cooldown is
not remediated until the timer expires. Failures of other workers remain
eligible, subject to the global concurrency circuit breaker.

## State Model

The workflow must be persistent and idempotent so that restarting the
coordinator does not repeat unsafe actions.

```text
Healthy -> Suspect -> Fencing -> Storage fencing
                                 |
                                 v
              Healthy <- Cooldown <- Unfencing <- Recovering

Disabled: observed but not automatically remediated
```

`Fencing` stops and verifies the VM. `Storage fencing` applies out-of-service
and quarantine taints and waits for volume release. `Recovering` starts the VM
and requires stable Kubernetes `Ready`; `Unfencing` retains quarantine until
storage access is restored. Any active state may record an error and retry
without discarding the last confirmed safe state.

### Persistent Coordination State

The controller stores workflow state and timestamps as Kubernetes Node
annotations. Safety state also exists in Node taints and CSI-Addons
`NetworkFence` resources; leader ownership is stored in a Kubernetes `Lease`.

```text
Controller restart or leader change
              |
              v
Node annotations + taints + NetworkFence + leader Lease
              |
              v
Resume the current idempotent transition
```

Controller pod replacement therefore does not intentionally restart a
remediation from the beginning.

## Target Failure Handling

The following table describes the portable target. In the pilot, PVE execution
fencing must succeed before storage is released, and application recovery is
left to Kubernetes rather than actively retried by the controller.

| Condition | Behaviour |
| --- | --- |
| Compute API unavailable, all storage fencing succeeds | Recover workloads; keep the worker quarantined until execution recovery is available. |
| Storage fencing unavailable, execution fencing confirmed | Recover workloads using execution isolation. |
| Neither fence succeeds | Keep volumes attached, retry, and alert. |
| Replacement workload fails | Keep the old node fenced and continue application recovery attempts. |
| Worker recovery fails | Leave workloads on healthy nodes and keep the worker quarantined. |
| Several nodes fail together | Open the circuit breaker and avoid automatic mass fencing. |
| Compute host fails | Rely on confirmed platform HA or host fencing before releasing workloads. |

## Compute Host Failures

Guest-level operations are sufficient for VM, operating-system, kubelet, and
guest-network failures. A complete compute host failure additionally requires
platform HA or independent host fencing to prove that its guests cannot
continue running.

The platform HA system and the remediation coordinator must not independently
control the same machine. Their ownership and hand-off rules must be explicit.
For the initial implementation, these rules apply to Proxmox HA and worker VMs.

## Current Safety Boundaries

- Only worker nodes are remediated; control-plane remediation is out of scope.
- One remediation is active by default, limiting correlated-failure impact.
- Loss of the Kubernetes or PVE control path can stop progress safely.
- The initial pilot requires PVE execution fencing; portable storage-only
  fallback remains a target capability.
- The PVE credential needs power control over every configured worker VM. The
  deployment credential currently propagated to the controller may have broader
  privileges and must be treated as a privileged cluster secret.
- A repeat failure of the same node during cooldown may wait up to 10 minutes
  before remediation starts.

## Observability

Prometheus exposes the controller leader, per-worker phase, phase age, Lease
age, and recorded-error status. Grafana summarizes these phases:

| Phase | Meaning | Expected automatic action |
| --- | --- | --- |
| `Healthy` | Normal operation | Watch the Node Lease. |
| `Suspect` | Node loss is being confirmed | Return healthy or begin fencing. |
| `Fencing` | VM execution is being stopped | Confirm the VM is stopped. |
| `Storage fencing` | Storage ownership is being released | Wait with the VM stopped. |
| `Recovering` | VM is starting or Kubernetes health is stabilizing | Wait for stable `Ready`. |
| `Unfencing` | Storage access is being restored | Keep the node quarantined. |
| `Cooldown` | Node is usable but repeat remediation is suppressed | Return to `Healthy` when the timer expires. |
| `Disabled` | Automatic remediation is disabled for this worker | Observe only. |

An active phase with increasing age and an error metric indicates a retrying or
blocked transition; logs and the Node's last-error annotation provide detail.

## Expected Service Level

The initial pilot target for a single worker failure is:

- Failure detection and confirmation: approximately 25-30 seconds.
- Fencing and volume release: under 1 minute after detection.
- Workload recovery: application-dependent, typically 30-90 seconds.
- Expected total RTO for a singleton PostgreSQL workload: approximately 1-2
  minutes, plus any extended WAL recovery.
- After reintegration, the worker remains fully usable during its 10-minute
  per-node remediation cooldown; only repeat remediation is delayed.

These values are objectives to validate through failure testing, not guarantees.

## Acceptance Criteria

- A network-isolated worker cannot continue writing after its exclusive volumes
  move.
- A singleton workload with an exclusive CSI volume becomes ready on another
  worker without human intervention.
- The failed worker is restarted or replaced and returns automatically.
- Restarting the coordinator during any workflow state is safe.
- Loss of either compute or storage fencing still permits recovery through the
  other mechanism when all affected volumes are safely covered.
- Loss of both fencing paths never causes an unsafe detach.
- Multiple simultaneous node failures activate the circuit breaker.
- All state transitions, fencing evidence, retries, and recovery timings are
  observable and auditable.
