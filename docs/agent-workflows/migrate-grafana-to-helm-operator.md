# Migrate Grafana to Helm and Grafana Operator Workflow

Use this workflow when the user asks, in one high-level request, to migrate an
existing real cluster's manifest-managed Grafana workload to the official Helm
chart and enable Grafana Operator. The agent owns the complete sequence from
discovery through steady-state verification; the user does not need to request
each internal phase separately.

Apply this workflow together with:

- `docs/agent-workflows/update-cluster-from-repo.md`
- `docs/agent-workflows/monitoring-version-migration.md`
- `docs/grafana-helm-migration.md`
- `docs/grafana-operator-provisioning.md`

Use the cluster comparison and confirmation requirements from
`update-cluster-from-repo.md`. Its no-deployment rule applies to a
configuration-refresh request; this migration workflow may deploy only after
the explicit cluster-and-section permission required below and by `AGENTS.md`.

This workflow is repo-local guidance for agents. It is not a globally installed
Codex skill and does not relax the authorization rules in `AGENTS.md`.

## Intended Outcome

At completion, all of the following must be true:

- the official Grafana Helm chart owns the Grafana Deployment and Service
- the existing Grafana data PVC, PostgreSQL, ingress, TLS, credentials,
  datasources, and repository-managed dashboards remain intact
- Grafana Operator and its CRDs are installed cluster-wide
- the `Grafana` resource `monitoring/grafana-primary` registers the
  Helm-managed Grafana as an external instance
- Grafana resources in authorized namespaces can target that instance with the
  `grafana/instance: primary` selector
- `grafana_helm_take_ownership` is back to `false`, so normal Helm operations
  use atomic upgrades and standard ownership checks
- the live `monitoring` deployment record reflects the final clean platform and
  cluster revisions

The migration normally requires two monitoring deployments under one migration
objective:

1. a takeover deployment with `grafana_helm_take_ownership = true`
2. a steady-state deployment after returning that value to `false`

Operator installation, CRD installation, external-instance registration, and
the Grafana Helm takeover may be performed in the first deployment. The
operator release explicitly depends on the Grafana release, and its chart
installs the CRDs before rendering the registered `Grafana` custom resource.

## Human Interaction and Authorization

The user may initiate the whole workflow with one request such as:

> Migrate Grafana to Helm and enable Grafana Operator in `<cluster>`.

Do not require the user to discover or name the internal phases. Continue the
same objective across reviews, commits, deployments, and verification, but
honor these boundaries:

- Require an explicit real cluster name.
- Perform read-only discovery before changing files.
- Present the cluster-update confirmation report required by
  `update-cluster-from-repo.md` before editing cluster-local files.
- Editing permission does not authorize a commit, push, or deployment.
- Obtain explicit authorization before committing or pushing each repository.
- Obtain explicit deployment permission naming the cluster and `monitoring`
  section before each `scripts/deploy.sh` invocation, unless the user clearly
  authorized both monitoring-only invocations in advance.
- Do not broaden either deployment beyond `monitoring` without renewed
  permission.
- Do not use `--development` unless the user explicitly authorizes development
  mode for this migration.

When pausing at an authorization boundary, explain the next operation and why
it is required, then resume the same migration objective after authorization.

## State Classification

Classify the cluster before proposing changes. Do not assume that every cluster
starts from the same point.

| State | Evidence | Next action |
|---|---|---|
| Legacy | Manifest state owns Grafana Deployment and Service; no Grafana Helm release | Run the full takeover path |
| Operator only | Operator release and CRDs exist; Grafana remains manifest-managed | Preserve Operator and run the takeover path |
| Takeover pending | Source enables Helm and takeover, but no Grafana Helm release exists | Validate preflight and run the takeover deployment |
| Takeover completed | Grafana Helm release exists and legacy state addresses are absent, but takeover remains enabled | Verify health, set takeover to `false`, and run the steady-state deployment |
| Steady state | Grafana Helm release and Operator are healthy, legacy state is absent, and takeover is `false` | Validate and report; do not repeat migration |
| Inconsistent | Helm and legacy state both claim Grafana, expected live resources are missing, or source/state/live ownership disagree | Stop normal migration and use the recovery rules below |

An interrupted attempt may legitimately have no legacy Deployment while a Helm
release or migrated OpenTofu state already exists. Classify from source, live
resources, Helm, and OpenTofu state together instead of treating one missing
resource as proof that it is safe to restart from the beginning.

## Read-Only Discovery and Preflight

Run commands from `clusters/<cluster>` with `.envrc` loaded through
`direnv exec .`.

1. Confirm the platform and cluster repositories' branches, HEAD revisions,
   upstream revisions, and worktree status. Preserve unrelated changes and stop
   before deployment if either repository is dirty.
2. Read `scripts/deployment-status.sh show`. Compare the live `monitoring`
   platform and cluster revisions with both repository HEADs, inspect changed
   paths, and distinguish operational drift from documentation-only or
   runtime-state-only drift.
3. Compare the cluster's monitoring constants with `clusters/sample` and the
   current consumers in `monitoring/main.tf`. Also compare the deployment
   section and generated-workspace sets, explicitly reporting additions and
   removals even when there are none.
4. Record without exposing secrets:
   - Grafana and PostgreSQL readiness, images, and restart counts
   - Grafana Service name, ClusterIP, ports, and selector
   - Grafana data and dashboard-provisioning PVC/PV bindings
   - Grafana ingress and TLS Secret names
   - `/api/health` result from inside the cluster
   - existing `grafana` and `grafana-operator` Helm releases
   - existing Grafana Operator CRDs and `Grafana` resources
5. Confirm that `ConfigMap/monitoring/grafana` and
   `ServiceAccount/monitoring/grafana` do not unexpectedly exist before a
   legacy takeover. The chart creates them and the migration guard rejects an
   ownership collision.
6. Inspect `out/monitoring` state. A normal legacy starting point contains
   exactly these Grafana workload addresses:

   ```text
   kubernetes_manifest.monitoring_other["monitoring/Deployment/grafana"]
   kubernetes_manifest.monitoring_other["monitoring/Service/grafana"]
   ```

   Do not run `tofu state rm` manually.
7. Run `tofu init`, `tofu validate`, and a refresh-free plan in
   `out/monitoring`. Do not use the refresh-free plan as evidence that live
   health or ownership is correct.

Before editing, present the confirmation table required by
`update-cluster-from-repo.md`. Identify `monitoring_constants.tf` as the normal
cluster-local edit, `out/monitoring` as the validation workspace, and state
that the migration causes a short Grafana interruption because its immutable
Deployment selector requires replacement. The PVC and PostgreSQL workload are
not replaced.

## Takeover Configuration

For a legacy cluster, preserve its existing image tag, storage, authentication,
resource sizing, domain, and TLS values. Add or update only the migration and
Operator settings:

```hcl
# One-time migration to Helm. Return takeover to false after the first
# successful Helm install; keep Helm enabled for steady-state management.
grafana_helm_enabled        = true
grafana_helm_take_ownership = true
grafana_helm_chart_version  = "13.2.5"

grafana_operator_enabled                    = true
grafana_operator_register_existing_instance = true
grafana_operator_chart_version              = "5.25.0"
grafana_operator_cpu_request                = "100m"
grafana_operator_cpu_limit                  = "500m"
grafana_operator_mem_request                = "256Mi"
grafana_operator_mem_limit                  = "256Mi"
```

Use the versions and baseline resources currently declared by
`clusters/sample`; the values above document the baseline at the time this
workflow was introduced and are not permission to downgrade or silently change
future pins. Preserve cluster-specific values when they intentionally differ.

Validate the resulting workspace again. Show the user the exact source diff
and the relevant refresh-free plan summary before requesting commit or
deployment authorization.

## Takeover Deployment

Normal deployment requires the reviewed platform and cluster source changes to
be committed and pushed. Propose English commit subjects following
`AGENTS.md`; do not commit merely because the migration was requested.

After explicit permission for the named cluster and monitoring section, run
only:

```bash
cd clusters/<cluster>
direnv exec . ../../scripts/deploy.sh --services-only \
  --skip-ceph --skip-k8s-net --skip-identity --skip-s3-storage \
  --skip-platform --skip-kafka --skip-benchmark
```

Do not remove the legacy Deployment, alter state, annotate the Service for
Helm, or install either chart manually. `deploy.sh` performs the guarded state
handoff immediately before apply. It verifies the live Service, data PVC,
PostgreSQL, and legacy Grafana Deployment; removes only the two expected legacy
addresses from a validated state copy; deletes only the legacy Deployment; and
lets Helm recreate the Deployment and adopt the Service.

The same OpenTofu apply then installs Grafana Operator after Grafana. Do not
split Operator installation and external-instance registration into separate
deployments unless a cluster-specific failure or explicit user request makes
that necessary.

## Validation After Takeover

Do not proceed to steady-state cleanup until all applicable checks pass:

1. `helm -n monitoring status grafana` reports a deployed release at the
   configured chart version.
2. Grafana and PostgreSQL are Ready with no unexpected restart increase.
3. Grafana still uses the configured image and existing `grafana-data` PVC.
4. The Grafana Service name, ClusterIP, port, ingress, and TLS Secret remain
   correct.
5. `/api/health`, Prometheus scraping, local administrator login, and Keycloak
   login work.
6. Existing dashboards and datasources remain available. Confirm the
   repository-managed Grafana internal, Grafana Operator, and Grafana Postgres
   dashboards are present when provided by the current platform revision.
7. `helm -n monitoring status grafana-operator` reports a deployed release.
8. The expected Grafana CRDs are established, including `Grafana`,
   `GrafanaDashboard`, `GrafanaDatasource`, `GrafanaFolder`, and
   `GrafanaAlertRuleGroup`.
9. The `Grafana` resource `monitoring/grafana-primary` reports
   `GrafanaReady=True`.
10. Operator metrics are scraped and the Grafana Operator dashboard identifies
    the current Operator pod without mixing unrelated monitoring pods.
11. Run the temporary datasource, dashboard, and alert-rule CRUD/deletion test
    described by `docs/grafana-operator-provisioning.md`, unless the user
    explicitly excluded functional tests. Remove all test resources and prove
    their remote Grafana entities were deleted.
12. Re-read deployment status and record the takeover deployment revisions.

If an interactive login cannot be verified by the agent, report it as a named
manual check rather than silently declaring the migration complete.

## Steady-State Cleanup

After successful takeover validation, change only:

```hcl
# Grafana is managed by Helm after the completed one-time state handoff.
# Keep takeover disabled during steady-state upgrades.
grafana_helm_enabled        = true
grafana_helm_take_ownership = false
grafana_helm_chart_version  = "13.2.5"
```

Keep Operator and external-instance registration enabled. Run `tofu validate`
and a refresh-free plan again, show the focused diff, and obtain the required
commit/push and monitoring deployment authorizations. Run the same
monitoring-only deployment command.

The second apply restores atomic Helm upgrades and normal ownership checks. It
must not recreate Grafana, replace PVCs, or change the Service ClusterIP. Verify
the Helm releases, workload health, Grafana CR condition, and deployment status
again. The migration is incomplete while the configured takeover value remains
`true`, even if Grafana is serving traffic.

## Recovery and Resume Rules

- Never uninstall either Helm release as a generic retry.
- Never delete Grafana or PostgreSQL PVCs, credentials, finalizers, CRDs, or
  production Grafana custom resources as a recovery shortcut.
- Never restore or edit OpenTofu state manually unless a separately reviewed
  recovery plan proves the exact source/live/state relationship.
- Preserve runtime state committed automatically by a failed normal deployment;
  it identifies how far the handoff progressed.
- Re-run read-only classification after a failure. The guarded migration is
  designed to recognize an already completed handoff, but the agent must prove
  the current state before retrying.
- If Helm exists and legacy state is absent, validate the release and continue
  from post-takeover checks or steady-state cleanup instead of restarting the
  legacy path.
- If both Helm and legacy state claim the workload, or Grafana, PostgreSQL, or
  the data PVC is unhealthy, stop and report the exact inconsistency. Do not
  broaden deployment scope without renewed permission.
- If a Grafana custom resource is stuck during deletion, inspect its status,
  finalizers, Operator logs, and remote entity state. Do not strip finalizers
  merely to make Kubernetes deletion complete.

## Required Final Report

Report the migration as one objective with the internal phases visible:

| Check | Result | Evidence or follow-up |
|---|---|---|
| Initial state classification | | |
| Repository and deployment provenance | | |
| Takeover validation | | |
| Grafana Helm release | | |
| Grafana Operator and CRDs | | |
| External Grafana registration | | |
| Dashboard and datasource preservation | | |
| Temporary resource deletion test | | |
| Steady-state `take_ownership = false` | | |
| Final workload and PVC health | | |
| Final deployment provenance | | |

Also state:

- every file and repository changed
- commit and push results, without exposing sensitive remote details
- the exact deployment command used for each invocation
- whether either deployment failed and from which classified state it can resume
- any manual checks still owed by the operator
- whether the migration is fully complete or paused at an authorization or
  health gate
