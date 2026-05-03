# Rancher + Keycloak authentication

This repository automates the Keycloak side of Rancher authentication and keeps the Rancher-side authorization setup explicit.

## Automation boundary

Automated in `identity`:

- A shared Keycloak realm group named `k8s-admins`.
- LDAP-to-Keycloak group mapping for that group.
- The Rancher OIDC client, including redirect URIs and a generated confidential client secret.
- The `groups` OIDC claim with full group path enabled.

Manual in Rancher:

- Enabling Keycloak OIDC as the Rancher auth provider.
- Restricting site access to approved groups.
- Binding Rancher groups to global, cluster, project, or namespace roles.
- Keeping local Rancher users for break-glass recovery.

## Keycloak configuration model

Declare Rancher access groups under `keycloak_realms[*].groups` in `clusters/<cluster>/identity_constants.tf`.

Declare the Rancher client under `keycloak_realms[*].oidc_clients`.

The sample cluster already includes `k8s-admins` and an OIDC client with redirect URI `https://<rancher-host>/verify-auth`.

## Retrieving generated OIDC settings

After applying the identity workspace, inspect the generated values from the cluster workspace:

```bash
tofu -chdir=out/identity output keycloak_oidc_client_metadata
tofu -chdir=out/identity output -json keycloak_oidc_client_secrets
```

Use:

- issuer URL: `https://<keycloak-host>/realms/<realm>`
- client ID: `rancher`
- client secret: from `keycloak_oidc_client_secrets`

## Rancher configuration

In Rancher:

1. Log in with the local bootstrap admin and keep that local user enabled.
2. Optionally create a second local admin as a break-glass account.
3. Configure `Keycloak (OIDC)` as the auth provider.
4. Use the Keycloak realm issuer URL and the generated Rancher client credentials.
5. Set site access to only authorized users and groups.
6. Add `k8s-admins` as the allowed group.

Do not remove local Rancher admins after external auth is enabled.

## Role model

Current simplified mapping:

- `k8s-admins`: shared administrative access group for Rancher now and Portainer later.

For Rancher, bind `k8s-admins` to the administrative role you want to start with. If you later need lower-privilege operator or read-only access, add separate Keycloak groups at that point instead of overloading `k8s-admins`.
