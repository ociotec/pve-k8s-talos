# Infrastructure priority migration

Use this workflow for the one-time migration to the new priority hierarchy.
Apply repository deployment authorization and monitoring checks as usual.

```text
Native system-*      unchanged
infra-k8s              1000000
infra-ceph              900000
infra-services          800000
infra-headroom          700000  (shared worker CPU/memory headroom)
infra-monitoring        600000
Unclassified pods           0
infra-benchmark        -100000  (no preemption)
```

## Before deployment

- Keep Kafka excluded unless its deployment is explicitly requested.
- Registry diagnostics run before k8s-net: they prefer `infra-monitoring` and
  temporarily use the lowest existing positive infrastructure class during the
  first migration. They must never use `infra-headroom` or a benchmark class.
- The `removed` blocks in k8s-net and benchmark forget the old manifest resources
  without deleting their PriorityClasses. New names are managed by typed
  PriorityClass resources. Do not move old state addresses to the new resources.
- For legacy Rancher, inspect the platform state for a `platform_other` instance
  whose object is exactly `PriorityClass/rancher-critical`. If present, back up
  the state privately and detach only that verified address with
  `tofu -chdir=out/platform state rm '<verified-address>'` before applying platform.
  This preserves the live class until the final cleanup. Do not detach other
  Rancher objects. Helm-mode clusters may have no such instance.
- Inspect plans: old classes must be forgotten, not destroyed, while new classes
  are created. Preserve existing platform resource indices when filtering the
  retired Rancher class.
- Existing MetalLB DaemonSets also need the automatic state handoff performed
  by `deploy.sh`: inspect it with `scripts/migrate-metallb-daemonset-state.py`
  without `--execute`. It checks the live UID and selector before detaching
  only the old manifest state, with a private backup. For a pre-deployment plan,
  simulate that handoff on a private state copy. Never apply a bare plan which
  deletes the existing DaemonSet; server-side apply keeps the live object.

## Deployment and cleanup

1. Deploy the approved sections using `scripts/deploy.sh`. The new
   `priorityClassName` values update workload templates; no revision annotation
   or custom rollout reconciler is needed.
2. Wait for the changed workloads and storage controllers to recover. Verify
   effective pod priorities against the new classes. Ignore completed Jobs when
   checking current service health; their next executions use the new templates.
3. Inspect references in pods, Deployments, StatefulSets, DaemonSets, Jobs,
   CronJobs, operator configuration, and retained ReplicaSets. A retained old
   ReplicaSet needs its old class if it will be used for rollback. Keep the class
   until that rollback dependency is deliberately retired.
4. Only after verifying there are no remaining consumers, manually delete the
   unused classes: `infra-high`, `infra-critical`, `infra-observability`,
   `benchmark-low`, and `rancher-critical`. Do not delete native `system-*` or
   unrelated classes. Never force deletion to bypass a remaining consumer.

There is no automatic class-deletion script. Cleanup is a one-time agent or
operator action under the approved deployment scope. In development mode,
preserve the local state and marker until consolidation from the same PC.

## Rancher background reconciliation

Repeat the Rancher systems readiness check after deployment. A managed chart can
start another reconciliation after the platform section has returned.

Helm 4 server-side apply can conflict with repository resource patches on the
Turtles Deployment. If that coincides with a webhook interruption, a terminated
Helm container can leave a release in `pending-upgrade` while its proxy sidecar
keeps the operation Pod running. Do not treat that Pod as a successful operation.

For a recovery within an authorized platform deployment:

1. Verify two stable webhook replicas and working Secret admission. Inspect the
   latest operation's Helm error without exposing tokens or command arguments.
2. Identify the last successful release revision. Require identical chart and
   application versions; a cross-version rollback needs a separate assessment.
3. Dry-run a normal Helm rollback to that revision with `--server-side=false`
   and `--dry-run=server`. If it succeeds, use the same rollback with readiness
   waits. Never edit release Secrets or force resource replacement.
4. Allow Rancher to reconcile the desired chart values. Then reapply the exact
   repository-managed resource/priority patches for Turtles and its CAPI child
   controller, since recovery can restore default requests and recreate child
   workloads without their repository priority.
5. Verify the release remains deployed, requests/limits and priority match the
   source, and the Rancher systems check passes again. Preserve private recovery
   evidence. Do not hide a pending or failed release with health-check bypasses.
