# Rancher, Portainer, Grafana + Keycloak authentication

This repository automates the Keycloak side of Rancher, Portainer, and Grafana authentication.

## Automation boundary

Automated in `identity`:

- A shared Keycloak realm group named `k8s-admins`.
- LDAP-to-Keycloak group mapping for that group.
- The Rancher OIDC client, including redirect URIs and a generated confidential client secret.
- The Portainer OIDC client, including redirect URI and a generated confidential client secret.
- The Grafana OIDC client, including redirect URI and a generated confidential client secret.
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

Manual recovery paths:

- Keeping local Rancher users for break-glass recovery.
- Keeping the local Portainer admin password for recovery.
- Keeping the local Grafana admin password for recovery and administrative tasks.

## Keycloak configuration model

Declare access groups under `keycloak_realms[*].groups` in `clusters/<cluster>/identity_constants.tf`.

Declare the Rancher, Portainer, and Grafana clients under `keycloak_realms[*].oidc_clients`.

The sample cluster already includes `k8s-admins`, a Rancher client with redirect URI `https://<rancher-host>/verify-auth`, and a Portainer client with redirect URI `https://<portainer-host>/`.
For Grafana, use redirect URI `https://<grafana-host>/login/generic_oauth`.

## Retrieving generated OIDC settings

After applying the identity workspace, inspect the generated values from the cluster workspace:

```bash
tofu -chdir=out/identity output keycloak_oidc_client_metadata
tofu -chdir=out/identity output -json keycloak_oidc_client_secrets
```

Use:

- issuer URL: `https://<keycloak-host>/realms/<realm>`
- client ID: `rancher`, `portainer`, or `grafana`
- client secret: from `keycloak_oidc_client_secrets`

## Platform configuration

In `clusters/<cluster>/platform_constants.tf`, enable the integrations by setting:

```hcl
rancher_auth_keycloak_realm   = "company"
rancher_auth_allowed_group    = "k8s-admins"
portainer_auth_keycloak_realm = "company"
```

Do not remove local Rancher or Portainer admins after external auth is enabled.

For an existing Portainer data volume, deployment treats the OpenTofu-generated admin password as authoritative. If the local Portainer database has drifted, the OAuth configuration step reconciles the local admin password back to the generated state value before calling the Portainer API.

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

Use `monitoring-view` for Grafana `Viewer` access and `monitoring-edit` for Grafana `Editor` access. Keep the local Grafana `admin` user for server administration and break-glass recovery.

## Role model

Current simplified mapping:

- `k8s-admins`: shared administrative access group for Rancher and Portainer.
- `monitoring-view`: Grafana Viewer access.
- `monitoring-edit`: Grafana Editor access.

For Rancher, `k8s-admins` is bound to the configured global role. For Portainer, Keycloak restricts login for the `portainer` client to the configured `login_allowed_groups`. Portainer CE then keeps its usual local authorization model; deployment creates the configured default team, assigns auto-created OAuth users to it, grants that team access to the existing Portainer environments, and grants the team access to Kubernetes namespaces that exist at apply time. Use `portainer_auth_default_team_existing_users` to reconcile OAuth users that logged in before this default team was configured. Keep local Portainer admin access for break-glass recovery.
For Grafana, Keycloak restricts login for the `grafana` client to the configured groups, and Grafana maps those groups to `Viewer` or `Editor`. Grafana OSS `Viewer` is intentionally strict; users who need Explore and dashboard editing should be in `monitoring-edit`.
