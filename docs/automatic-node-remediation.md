# Automatic Node Remediation and Stateful Workload Recovery

Status: Proposed

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

The remediation coordinator should run outside the Kubernetes cluster it
protects. This keeps the recovery path available during partial cluster
failures.

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
Wait for affected services to become ready
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

A node is a remediation candidate when it remains `Unknown` or `NotReady`
beyond a configured threshold. Detection must include circuit breakers:

- Remediate workers only.
- Require a healthy Kubernetes control plane.
- Limit the number of simultaneous unhealthy nodes.
- Pause during declared maintenance.
- Rate-limit repeated remediation attempts.

The detector should watch Kubernetes node state directly. Monitoring alerts are
useful for visibility but should not be the control signal.

### Fencing

The coordinator attempts both mechanisms:

1. **Execution fencing:** use the compute adapter to isolate the worker and
   verify that it can no longer execute workloads.
2. **Storage fencing:** use the adapter for each affected CSI driver to revoke
   the worker's access to its writable volumes.

Recovery may continue when execution fencing succeeds, or when storage fencing
succeeds for every affected writable volume. Using both provides defense in
depth and allows recovery when one control path is unavailable.

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

Recovery completes only when the affected replacement workloads pass their
readiness checks. A failed application recovery does not undo fencing or return
the old node to service.

### Worker Recovery

Once workloads are safe elsewhere, the coordinator recovers the worker:

1. Ask the execution adapter to restart, relocate, replace, or power-cycle the
   worker as appropriate.
2. Verify that its boot identity changed.
3. Require the node to remain healthy for a stabilization period.
4. Remove the out-of-service state and wait for storage unfencing.
5. Remove quarantine and make the node schedulable.

A separate quarantine prevents workloads from reaching the node during the
storage unfencing cooldown.

## State Model

The workflow must be persistent and idempotent so that restarting the
coordinator does not repeat unsafe actions.

```text
Healthy
  -> Suspected
  -> Quarantined
  -> Fencing
  -> Fenced
  -> Evacuating
  -> WorkloadsRecovered
  -> NodeRecovering
  -> NodeStabilizing
  -> Reintegrated
```

Any state may enter a retrying error condition. Error handling must preserve the
last confirmed safe state.

## Failure Handling

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

## Expected Service Level

An initial target for a single worker failure is:

- Failure detection: 2-3 minutes.
- Fencing and volume release: under 1 minute after detection.
- Workload recovery: application-dependent, typically 1-3 minutes.
- Expected total RTO for a singleton PostgreSQL workload: approximately 3-6
  minutes.

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
