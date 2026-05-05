# Rancher, Portainer + Keycloak authentication

This repository automates the Keycloak side of Rancher and Portainer authentication.

## Automation boundary

Automated in `identity`:

- A shared Keycloak realm group named `k8s-admins`.
- LDAP-to-Keycloak group mapping for that group.
- The Rancher OIDC client, including redirect URIs and a generated confidential client secret.
- The Portainer OIDC client, including redirect URI and a generated confidential client secret.
- Optional Keycloak-side Portainer login restriction by OIDC client `login_allowed_groups`.
- The `groups` OIDC claim with full group path enabled.

Automated in `platform`:

- Rancher Keycloak OIDC `AuthConfig`.
- Rancher global role binding for the configured group.
- Portainer local bootstrap admin password.
- Portainer custom OAuth settings via the Portainer API.

Manual recovery paths:

- Keeping local Rancher users for break-glass recovery.
- Keeping the local Portainer admin password for recovery.

## Keycloak configuration model

Declare Rancher access groups under `keycloak_realms[*].groups` in `clusters/<cluster>/identity_constants.tf`.

Declare the Rancher and Portainer clients under `keycloak_realms[*].oidc_clients`.

The sample cluster already includes `k8s-admins`, a Rancher client with redirect URI `https://<rancher-host>/verify-auth`, and a Portainer client with redirect URI `https://<portainer-host>/`.

## Retrieving generated OIDC settings

After applying the identity workspace, inspect the generated values from the cluster workspace:

```bash
tofu -chdir=out/identity output keycloak_oidc_client_metadata
tofu -chdir=out/identity output -json keycloak_oidc_client_secrets
```

Use:

- issuer URL: `https://<keycloak-host>/realms/<realm>`
- client ID: `rancher` or `portainer`
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

## Role model

Current simplified mapping:

- `k8s-admins`: shared administrative access group for Rancher and Portainer.

For Rancher, `k8s-admins` is bound to the configured global role. For Portainer, Keycloak restricts login for the `portainer` client to the configured `login_allowed_groups`. Portainer CE then keeps its usual local authorization model; deployment creates the configured default team, assigns auto-created OAuth users to it, grants that team access to the existing Portainer environments, and grants the team access to Kubernetes namespaces that exist at apply time. Use `portainer_auth_default_team_existing_users` to reconcile OAuth users that logged in before this default team was configured. Keep local Portainer admin access for break-glass recovery.
