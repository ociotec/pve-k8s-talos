# Monitoring Version Migration Workflow

Use this workflow when a real cluster will receive an upgrade or migration of
the monitoring stack. Apply it together with
`docs/agent-workflows/update-versions.md` when the request includes version
selection or image updates.

This workflow is repo-local guidance for agents. It is not a globally installed
skill.

## Trigger Conditions

Use this workflow for a real cluster whenever a requested monitoring change
includes one or more of:

- Tempo, including a major-version, storage-format, backend, WAL, compaction,
  or retention change.
- OpenTelemetry Collector or OpenTelemetry Collector Contrib images,
  pipelines, receivers, exporters, extensions, or telemetry settings.
- Prometheus, Loki, Grafana, PostgreSQL, kube-state-metrics, oauth2-proxy,
  exporters, or image version changes under `monitoring/`.
- Pod scrape annotations, Prometheus relabeling, ConfigMaps consumed by a
  monitoring workload, or monitoring dashboards that depend on changed
  metrics.

Do not use this workflow for a documentation-only change or a read-only
version inventory. For a read-only request, perform only the non-mutating
preflight and report the applicable risks.

## Authorization Boundaries

- Require an explicit cluster name before inspecting a real cluster.
- A deployment requires explicit permission for that cluster and the
  `monitoring` section, as required by `AGENTS.md`.
- Do not modify an active Tempo PVC merely because a validator found malformed
  data. First prove the proposed repair on a clone, report the exact affected
  block directories, and obtain explicit authorization for the active-volume
  repair unless the user already authorized that precise repair.
- Never delete a Tempo PVC, its contents, or a RBD snapshot as a migration or
  recovery shortcut.
- Do not display credentials, tokens, kubeconfigs, private endpoints, or
  unredacted generated credential documents.

## Preflight

Run from `clusters/<cluster>` with the cluster `.envrc` loaded.

1. Confirm both the platform and cluster repositories are clean. A
   `scripts/deploy.sh` run will otherwise stop before applying the requested
   section.
2. Read the live deployment provenance with:

   ```bash
   direnv exec . ../../scripts/deployment-status.sh show
   ```

   Compare the recorded `monitoring` platform and cluster revisions with the
   respective repository heads. Report operational drift before proceeding.
3. Record the running images, readiness, restarts, and relevant events for
   monitoring workloads. Preserve this as the pre-migration baseline; it is
   more useful than comparing only the desired source versions.
4. Run `tofu init` and `tofu validate` in `out/monitoring`. Run a
   refresh-free plan when the workspace and provider support it.
5. Determine whether any consumed ConfigMap changes without a corresponding
   pod-template checksum. Such workloads will not reliably reload their new
   configuration just because the ConfigMap changes.

## Tempo Data-Safety Gate

Apply this gate when Tempo changes major version, storage format, backend,
WAL, compaction behavior, or any path that reads pre-existing blocks. Run it
before the production migration whenever practical.

1. Identify the active Tempo PVC, PV, and its RBD image without printing
   sensitive cluster data.
2. Create and protect a point-in-time snapshot. Prefer a Kubernetes
   `VolumeSnapshot` only when the required CRDs and snapshot class exist. If
   they are unavailable, use the Rook Ceph RBD snapshot-and-clone path.
3. Mount the clone in a temporary, isolated workload. An ext4 volume may need
   a read-write mount to replay its journal; this is safe on the clone, never
   on a supposed read-only production mount.
4. Parse every `*.json` file under the Tempo traces path. Record only invalid
   relative paths and parser errors; never print trace contents.
5. Start the target Tempo image against the clone and check its blocklist
   polling logs. This proves whether malformed metadata is the actual cause,
   rather than assuming any migration error is a data-corruption problem.

### Repair Rule for Invalid Tempo Block Metadata

If the clone reproduces an error such as `failed reading unknown blocks` or
`unexpected end of JSON input` and identifies one or more invalid block
metadata files:

1. Keep the protected snapshot and clone until recovery validation completes.
2. On the clone, move each affected **whole block directory** to a dated
   `quarantine` directory outside the trace path. Do not delete individual
   files or infer replacement metadata.
3. Restart Tempo against the repaired clone and require a successful blocklist
   poll before proposing the production repair.
4. With explicit authorization, scale Tempo down, move the same whole block
   directories on the active PVC to the dated quarantine, then scale Tempo
   back to its previous replica count.
5. Wait for readiness, a successful `blocklist poll complete`, and at least
   one successful compaction when work exists. The isolated `no jobs found`
   scheduler message is known background noise in Tempo 3 single-binary mode;
   do not treat it as data loss or a failed migration by itself.

The failed blocks may make only their historical trace ranges unavailable. The
quarantine and protected snapshot preserve a reversible recovery path.

## OpenTelemetry and Prometheus Gate

Apply this gate whenever an OpenTelemetry Collector image, its ConfigMap, its
scrape annotations, or Prometheus discovery/relabeling changes.

1. Require each collector configuration to expose telemetry metrics with the
   current OTel syntax:

   ```yaml
   service:
     telemetry:
       metrics:
         readers:
           - pull:
               exporter:
                 prometheus:
                   host: "0.0.0.0"
                   port: 8888
   ```

2. Ensure both internal and public collector pod templates have the expected
   Prometheus scrape annotations and a named or declared metrics port.
3. Ensure Prometheus discovery builds a target address from the pod IP and the
   annotated port, and excludes init containers.
4. A ConfigMap update alone is insufficient for a running collector. Prefer a
   deterministic ConfigMap checksum annotation on every consuming pod
   template. Until that exists, explicitly roll out the affected collector
   deployments after the ConfigMap is applied, one at a time.
5. Query Prometheus after the scrape interval. The check must show both
   collector targets and each must be `up = 1`:

   ```promql
   up{namespace="monitoring",pod=~"otel-collector.*"}
   ```

   A missing target means discovery or annotations are wrong. A target with
   `up = 0` normally means the collector did not load the telemetry listener
   or it is not reachable on the pod IP. Inspect the ConfigMap and rollout
   status before changing Prometheus.

## Minimal Deployment and Post-Deployment Validation

For monitoring-only changes, use the minimum deployment scope after receiving
the required permission:

```bash
cd clusters/<cluster>
direnv exec . ../../scripts/deploy.sh --services-only \
  --skip-ceph --skip-k8s-net --skip-identity --skip-s3-storage \
  --skip-platform --skip-kafka --skip-benchmark
```

After the deployment:

1. Wait for the rollouts of every changed deployment. Check that all current
   monitoring pods are Ready with no unexpected restarts; ignore completed or
   superseded ReplicaSet pods when assessing current health.
2. Review Kubernetes events for failed mounts, image pulls, probe failures, or
   repeated scheduling errors. A transient Tempo startup `503` while an
   appropriate startup probe is still progressing is not a failure.
3. Review logs for the components changed by the migration. Treat Tempo block
   metadata errors, crash loops, authentication failures, and persistent probe
   failures as actionable. Classify the isolated Tempo scheduler `no jobs
   found` message as non-actionable unless it coincides with availability or
   compaction failures.
4. Complete the OpenTelemetry and Prometheus gate, including the `up` query.
5. For a Tempo migration, wait through a blocklist polling interval and confirm
   normal polling. Confirm compaction succeeds when there is eligible work.
6. Re-read `deployment-status.sh show` and confirm the `monitoring` section
   was advanced by `deploy.sh` with clean platform and cluster revisions.
7. Remove temporary pods, ConfigMaps, and static PV/PVC wrappers used for
   clone analysis. Retain the protected snapshot and RBD clone until the
   operator confirms the recovery window has elapsed; remove them only with
   explicit authorization.

## Required Report

Report the following after every real-cluster monitoring migration:

| Check | Result | Evidence | Follow-up |
|---|---|---|---|
| Deployment provenance | | | |
| Changed workload rollouts | | | |
| Tempo blocklist and compaction | | | |
| Tempo clone validation, if applicable | | | |
| OpenTelemetry target health | | | |
| Kubernetes events and restarts | | | |
| Recovery snapshot/clone state, if applicable | | | |

State clearly whether the active Tempo data was untouched, only quarantined,
or otherwise requires an operator decision. Include the exact minimal
deployment command run, or state that no deployment was needed.

## Known Baseline from gcs-beta

The following observations are decision rules, not universal failures:

- Tempo 3 can expose pre-existing empty or malformed `meta.json` files when it
  reindexes historical blocks. The condition is data-dependent: it was found
  in `gcs-beta`, while healthy Tempo 3.0.2 instances did not show the same
  block-metadata error in `gcs-dev` or `argos-dev`.
- OpenTelemetry Collector telemetry metrics must bind to the pod interface.
  In the pre-migration configurations of `gcs-dev` and `argos-dev`, the public
  collector's Prometheus target was discovered but `up = 0` because the
  explicit telemetry listener configuration was absent.
- A monitoring deployment can successfully update a ConfigMap without
  restarting its consumer. Validate the running pod, not only the OpenTofu
  apply result.
