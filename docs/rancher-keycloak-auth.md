# Rancher, Portainer, Grafana + Keycloak authentication

This repository automates the Keycloak side of Rancher, Portainer, Grafana, Prometheus, and Redpanda Console authentication.

## Automation boundary

Automated in `identity`:

- A shared Keycloak realm group named `k8s-admins`.
- LDAP-to-Keycloak group mapping for that group.
- The Rancher OIDC client, including redirect URIs and a confidential client secret from `secrets/credentials.json`.
- The Portainer OIDC client, including redirect URI and a confidential client secret from `secrets/credentials.json`.
- The Grafana OIDC client, including redirect URI and a confidential client secret from `secrets/credentials.json`.
- The Redpanda Console OIDC client for ingress `oauth2-proxy`, including redirect URI and a confidential client secret from `secrets/credentials.json`.
- Optional Keycloak-side Portainer login restriction by OIDC client `login_allowed_groups`.
- Optional Keycloak-side Grafana login restriction by OIDC client `login_allowed_groups`.
- The `groups` OIDC claim with full group path enabled.

Automated in `platform`:

- Rancher Keycloak OIDC `AuthConfig`.
- Rancher global role binding for the configured group.
- Portainer local bootstrap admin password.
- Portainer custom OAuth settings via the Portainer API.

Automated in `monitoring`:

- Grafana generic OAuth settings from the generated Keycloak client metadata.
- Grafana group-to-role mapping for `Viewer` and `Editor`.
- Grafana OAuth client secret and optional private CA trust secret.

Automated in `kafka`:

- Redpanda Console ingress protection through `oauth2-proxy`.
- Redpanda Console OAuth client secret and optional private CA trust secret.

Manual recovery paths:

- Keeping local Rancher users for break-glass recovery.
- Keeping the local Portainer admin password for recovery.
- Keeping the local Grafana admin password for recovery and administrative tasks.

## Keycloak configuration model

Declare access groups under `keycloak_realms[*].groups` in `clusters/<cluster>/identity_constants.tf`.

Keep LDAP bind credentials out of `identity_constants.tf`. Declare the bind fields as `var.keycloak_ldap_bind_dn` and `var.keycloak_ldap_bind_credential`, then provide them from the cluster `.envrc` with `TF_VAR_keycloak_ldap_bind_dn` and `TF_VAR_keycloak_ldap_bind_credential`.

Declare the Rancher, Portainer, Grafana, Prometheus, and Redpanda Console clients under `keycloak_realms[*].oidc_clients`.

The sample cluster already includes `k8s-admins`, a Rancher client with redirect URI `https://<rancher-host>/verify-auth`, and a Portainer client with redirect URI `https://<portainer-host>/`.
For Grafana, use redirect URI `https://<grafana-host>/login/generic_oauth`.

## Retrieving OIDC settings

Service passwords and OIDC client secrets are persisted in `clusters/<cluster>/secrets/credentials.json`. `scripts/deploy.sh` runs `scripts/ensure-credentials.sh` before deployment to migrate missing values from existing local state when possible and create any remaining missing values. The identity workspace exposes the applied non-secret metadata through outputs:

```bash
tofu -chdir=out/identity output keycloak_oidc_client_metadata
```

Use:

- issuer URL: `https://<keycloak-host>/realms/<realm>`
- client ID: `rancher`, `portainer`, `grafana`, `prometheus`, or `redpanda-console`
- client secret: from `secrets/credentials.json`

## Platform configuration

### Rancher deployment modes

Rancher supports a temporary per-cluster deployment choice:

```hcl
# Omission preserves the existing manifest-based installation.
rancher_deployment_mode = "legacy"
rancher_version         = "2.12.2"
# Used only when deployment mode is helm.
rancher_chart_version   = "2.15.2"
# Explicit, destructive one-time reset; leave false for normal deployments.
rancher_helm_reinstall_legacy = false
```

Helm-only clusters should omit `rancher_version`; their effective application
version comes from the pinned chart. Keep the shared TLS, authentication,
replica, resource, and bootstrap password settings in both modes.

Helm mode is managed by the OpenTofu Helm provider in the existing `platform`
workspace. It is intended for new installations or a separately reviewed clean
replacement. Selecting `helm` does **not** authorize cleanup, migrate Rancher
data, adopt existing objects, or bypass the upstream supported upgrade path.
The chart 2.15.2 Kubernetes constraint is `<1.37.0-0`; the old 2.12.2 chart
requires `<1.34.0-0`. Check the Rancher support matrix as well as the chart
constraint when selecting a target; passing chart validation alone is not a
support certification for a Kubernetes distribution.

The deployment preparation rejects legacy Rancher objects still tracked in
OpenTofu state when Helm is selected, and rejects a tracked Helm release when
legacy is selected. Plan-time Kubernetes ownership checks also reject live
objects belonging to the other mode. Helm takeover is disabled. These
checks remain active even if the old Deployment has been removed: a retained
Rancher management CRD without a Helm-owned Deployment also blocks a fresh install, so old data
cannot silently be opened by a newer Rancher version. An interrupted first Helm
installation may require a separately reviewed recovery for the same reason.
Keep the guards active; do not work around them with manual state removal before
a normal deployment. Migration cleanup, state reconciliation, and partial-failure recovery
must be reviewed separately and run within the repository's deployment and state
synchronization rules.

For a disposable Rancher installation with only the `local` cluster, set
`rancher_helm_reinstall_legacy = true` to perform the reviewed replacement
automatically inside `deploy.sh`. `scripts/reinstall-rancher-for-helm.py` runs
after chart preparation, provider initialization and validation, and before the
ordinary state/live ownership guards and apply. It rejects downstream clusters,
user Fleet content, active CAPI provisioning, unknown internal controllers,
unrelated Helm releases in the internal namespaces, and PVCs in those namespaces.

Before stopping controllers it backs up Rancher CRDs and objects, internal
credentials, namespace metadata, native resource inventory and the original
platform state under the private cluster Git directory. It removes the known
Rancher/Fleet nested releases without hooks, their API registrations, legacy
workload resources, and data in an explicit allowlist of Rancher API groups.
Only after controllers stop can it remove finalizers on those backed-up Rancher
custom resources. Generic CAPI CRDs, application namespaces and PVCs are never
deleted. Old Rancher namespace ownership/project references are detached to
prevent namespace garbage collection and stale project assignments.

The migration verifies protected application object UIDs and the original TLS,
CA and bootstrap secret data. It then removes only the legacy workload and
Rancher integration addresses from a private state copy using OpenTofu, replaces
the authoritative local platform state, and proceeds to Helm installation and
OIDC/bootstrap reconciliation. A private journal permits retrying interrupted
cleanup on the same cluster and PC. An existing Rancher Helm state is never
reset by this flag. Return the flag to `false` after successful replacement.
The backup is recovery evidence; it is not a tested automatic rollback procedure.

For a clean replacement, inventory and back up Rancher first. Review the removal
of its controllers, webhook registrations, Fleet components, management CRs,
and legacy state addresses. Preserve application namespaces, workloads, PVCs,
the `cattle-system` namespace, repository-managed TLS/CA/bootstrap secrets, and
Keycloak client credentials. Removing only the Rancher Deployment does not erase
the old Rancher data and is not a clean replacement. Existing downstream cluster
registrations and user settings would be lost; use a supported upgrade/migration
instead if they must be retained. Never use a generic namespace or CRD purge as
an automatic migration step.

`scripts/prepare-rancher-chart.py` downloads the official archive, verifies its
pinned SHA-256, and prepares `.generated-rancher-chart.tgz` in the workspace.
It makes two narrow template adjustments because Helm excludes hooks from
post-rendering: omit the bootstrap Secret hook (OpenTofu owns that Secret),
and add CPU/memory resources plus `infra-observability` priority to the
pre-upgrade Job. The upstream pre-upgrade validation remains enabled. New chart
versions require a digest update and a compatibility review of these patches.
The Rancher container explicitly reads `CATTLE_BOOTSTRAP_PASSWORD` through the
existing Secret reference; omitting the chart hook must not omit that reference.
Before enabling OIDC, Helm deployments ensure that a local `admin` account
exists for break-glass access. Existing local admins are never reset. If the
account is absent, the official `ensure-default-admin` helper creates it and a
private API handshake immediately reconciles its password to the existing
bootstrap Secret. Recovery output is never printed; an interrupted handshake
keeps a private journal in the cluster Git directory for retry. Its temporary
API sessions have a two-minute TTL and are deleted after verification.

The post-renderer uses Python 3/PyYAML, adds ownership labels, and removes the
chart's private PriorityClass in favor of the shared `infra-observability`
class. CPU/memory values, Go runtime limits, hostname, TLS secret and private CA
remain cluster-configured. The chart's post-delete namespace cleanup is disabled,
including during a failed atomic install. TLS Secrets and cert-manager
Certificates remain outside Helm ownership. OIDC and group bindings are reapplied
when the selected deployment mode or version changes.

Rancher 2.15 uses the Turtles controller in `cattle-turtles-system`; the platform
patch set no longer waits for the legacy provisioning CAPI controller or the
separate local `api-extension` Deployment. Turtles retains the chart's 600Mi
memory ceiling with an equal reservation and uses `infra-high` priority. Its
CAPI controller in `cattle-capi-system` receives explicit CPU/memory resources
(100m/500m CPU and 256Mi reserved/limited memory) and `infra-high` priority. Older
Rancher versions retain their existing controller patch sets.
The local Fleet agent receives the same resource envelope and priority, plus an
explicit probe exception because its managed Deployment configures no health
endpoint. Verify a supported endpoint before replacing that exception with probes.

Before applying, validate the generated workspace and render the prepared chart.
Require probes and CPU/memory requests/limits on every rendered regular service
container, resources on hook containers, unchanged TLS/OIDC inputs, and no
unrelated Portainer changes. After applying, verify Helm status, Rancher readiness,
local and OIDC login, cluster inventory, webhook/Fleet health and sustained API
responses without SQLite lock errors. `/healthz` alone does not cover SQL cache
health. A cross-version rollback may require restoring Rancher data; Helm rollback
alone is not a data restoration mechanism.

The eventual platform-only deployment command, after review, clean published
source and explicit cluster/section authorization, is:

```bash
cd clusters/<cluster>
direnv exec . ../../scripts/deploy.sh --services-only \
  --skip-ceph --skip-k8s-net --skip-identity --skip-s3-storage \
  --skip-kafka --skip-monitoring --skip-benchmark
```

This also evaluates Portainer because it shares `platform`. Unless the one-time
replacement flag is explicitly enabled, it stops at the migration guard on a
cluster which still has legacy Rancher.
No new deployment section or workspace is introduced.

### Authentication settings

In `clusters/<cluster>/platform_constants.tf`, enable the integrations by setting:

```hcl
rancher_auth_keycloak_realm   = "company"
rancher_auth_allowed_group    = "k8s-admins"
portainer_auth_keycloak_realm = "company"
```

Do not remove local Rancher or Portainer admins after external auth is enabled.

For an existing Portainer data volume, deployment treats the `secrets/credentials.json` admin password as authoritative. If the local Portainer database has drifted, the OAuth configuration step reconciles the local admin password back to that persisted value before calling the Portainer API.

Restrict Portainer OAuth login in `clusters/<cluster>/identity_constants.tf` by setting the `portainer` OIDC client groups:

```hcl
login_allowed_groups = ["k8s-admins"]
```

The identity job creates a `login` client role on the `portainer` client, assigns it to the configured groups, copies Keycloak's browser flow for that client, and adds a conditional deny step for users that do not inherit the role.

## Monitoring configuration

In `clusters/<cluster>/monitoring_constants.tf`, enable Grafana OAuth by setting:

```hcl
grafana_auth_keycloak_realm = "company"
grafana_auth_view_groups    = ["monitoring-view"]
grafana_auth_edit_groups    = ["monitoring-edit"]
```

The monitoring module reads the identity workspace outputs, resolves the `grafana` client secret, expands each configured logical group with its included LDAP group names, and sets Grafana generic OAuth environment variables.

Use `monitoring-view` for Grafana `Viewer` access and browser access to Prometheus. Use `monitoring-edit` for Grafana `Editor` access and browser access to Prometheus. Keep the local Grafana `admin` user for server administration and break-glass recovery.

## Role model

Current simplified mapping:

- `k8s-admins`: shared administrative access group for Rancher and Portainer.
- `monitoring-view`: Grafana Viewer access and browser access to Prometheus.
- `monitoring-edit`: Grafana Editor access and browser access to Prometheus.

For Rancher, `k8s-admins` is bound to the configured global role. For Portainer, Keycloak restricts login for the `portainer` client to the configured `login_allowed_groups`. Portainer CE then keeps its usual local authorization model; deployment creates the configured default team, assigns auto-created OAuth users to it, grants that team access to the existing Portainer environments, and grants the team access to Kubernetes namespaces that exist at apply time. Use `portainer_auth_default_team_existing_users` to reconcile OAuth users that logged in before this default team was configured. Keep local Portainer admin access for break-glass recovery.
For Grafana, Keycloak restricts login for the `grafana` client to the configured groups, and Grafana maps those groups to `Viewer` or `Editor`. Grafana OSS `Viewer` is intentionally strict; users who need Explore and dashboard editing should be in `monitoring-edit`. For Prometheus, Keycloak restricts login for the `prometheus` client and ingress-nginx delegates browser auth to oauth2-proxy; Prometheus itself does not provide per-user RBAC in this deployment.
For Redpanda Console, Keycloak restricts login for the `redpanda-console` client and ingress-nginx delegates browser auth to oauth2-proxy. Redpanda Console native OIDC is intentionally not used here because Console authentication is an Enterprise feature; the Community deployment keeps Console unauthenticated internally and protects only the browser ingress.
