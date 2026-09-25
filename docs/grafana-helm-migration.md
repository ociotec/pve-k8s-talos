# Grafana Helm workload migration

This procedure moves the existing Grafana `Deployment` and `Service` from
`kubernetes_manifest` ownership to the official Grafana Helm chart. Grafana
Operator continues to treat Grafana as an external instance; it does not own
the workload.

The migration deliberately keeps these resources outside the chart:

- `PersistentVolumeClaim/grafana-data`
- the PostgreSQL Deployment, Service, credentials, and PVC
- ingress and TLS resources
- datasource and dashboard ConfigMaps
- the dashboard synchronization Job

The image tag is also preserved, so chart adoption and a Grafana version
upgrade remain separate operations.

## Constants

```hcl
grafana_helm_enabled        = false
grafana_helm_take_ownership = false
grafana_helm_chart_version  = "13.2.5"
```

Existing clusters must start with both booleans set to `false`. New clusters
can enable Helm immediately while keeping takeover disabled.

## Preflight

1. Confirm the platform and cluster repositories are clean and pushed.
2. Confirm Grafana, PostgreSQL, and the `grafana-data` PVC are healthy. If the
   Operator and `Grafana/grafana-primary` already exist, confirm they are also
   healthy.
3. Run `tofu init`, `tofu validate`, and a refresh-free plan from the generated
   monitoring workspace.
4. Record the Grafana image, pod restart count, Service ClusterIP, PVC/PV, and
   the Grafana API health response.
5. Confirm `ConfigMap/grafana` and `ServiceAccount/grafana` do not already
   exist; the chart creates both and the migration guard rejects an unexpected
   collision.
6. Confirm the legacy state contains exactly:

   ```text
   kubernetes_manifest.monitoring_other["monitoring/Deployment/grafana"]
   kubernetes_manifest.monitoring_other["monitoring/Service/grafana"]
   ```

The Deployment selector changes from the legacy `app=grafana` selector to the
chart's recommended app labels. Kubernetes treats that field as immutable, so
`deploy.sh` verifies Grafana, PostgreSQL, the Service, and the data PVC before
removing only the legacy Deployment. The first Helm install then recreates it,
which causes a short Grafana outage. The Service is adopted in place and the
existing `grafana-data` claim is mounted through
`persistence.existingClaim`; neither PVC is deleted or transferred to Helm.

## Migration deployment

After review, set both flags to `true`. When installing Grafana Operator in the
same migration, enable the Operator but keep
`grafana_operator_register_existing_instance = false` for this first
deployment. Commit and push the platform and cluster changes, then deploy only
monitoring:

```bash
cd clusters/<cluster>
direnv exec . ../../scripts/deploy.sh --services-only \
  --skip-ceph --skip-k8s-net --skip-identity --skip-s3-storage \
  --skip-platform --skip-kafka --skip-benchmark
```

When takeover is enabled, `deploy.sh` performs a guarded state-only handoff
after `tofu validate` and immediately before apply. It requires the existing
Deployment and Service to be healthy, removes only their two legacy state
addresses from a validated temporary state copy, deletes only the legacy
Deployment, and lets Helm recreate that Deployment while adopting the Service.
The normal runtime-state synchronization records the result even if the later
apply fails, and a retry recognizes an already completed state handoff or an
already absent legacy Deployment.

Do not run the state removal manually before `deploy.sh`: it dirties the
tracked cluster state and normal deployment preflight will reject it.

## Post-deployment

Require all of the following before considering the migration complete:

- Helm release `grafana` is deployed with the pinned chart version.
- Grafana and PostgreSQL are Ready with no unexpected restarts.
- the Grafana image tag, Service name and port, PVC names, and public ingress
  are unchanged.
- `/api/health`, Prometheus scraping, local admin login, and Keycloak login
  work.
- the existing dashboards and datasources remain available.
- Grafana Operator and its CRDs are healthy when installed by this deployment.

After the first successful install, set
`grafana_helm_take_ownership = false`. If this migration installed the
Operator, also set `grafana_operator_register_existing_instance = true` now
that the CRDs exist. Commit and push those changes, and run the same
monitoring-only deployment again. This restores atomic Helm upgrades and normal
ownership checks on later updates. Require `Grafana/grafana-primary` to report
`GrafanaReady=True`, then run a temporary Operator
datasource/dashboard/alert CRUD and deletion test.

If the initial takeover fails, do not uninstall the release, remove finalizers,
delete PVCs, or retry with broader flags. Preserve the generated state, inspect
the Helm release and live Deployment/Service, and choose recovery based on the
point at which the adoption stopped.
