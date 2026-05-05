locals {
  portainer_hostname             = "portainer.${local.domain}"
  portainer_tls_secret_name      = "portainer-tls"
  portainer_admin_secret_name    = "portainer-admin"
  portainer_oauth_ca_secret_name = "portainer-oauth-ca"

  storage_class = "${local.ceph_name_prefix}-rbd-ec"

  portainer_image_tag              = "2.40.0"
  portainer_storage_class          = local.storage_class
  portainer_pvc_size               = "10Gi"
  portainer_admin_password_length  = 24
  portainer_auth_keycloak_realm    = "company"
  portainer_auth_user_identifier   = "preferred_username"
  portainer_auth_scopes            = "openid profile email"
  portainer_auth_sso               = true
  portainer_auth_auto_create_users = true
  portainer_auth_default_team_name = "k8s-admins"
  # RoleId 1 is Portainer's environment administrator role.
  portainer_auth_default_team_role_id = 1
  # Existing auto-created OAuth usernames to add to the default team on the next platform apply.
  portainer_auth_default_team_existing_users = []

  rancher_hostname                  = "rancher.${local.domain}"
  rancher_tls_secret_name           = "tls-rancher-ingress"
  rancher_replicas                  = 1
  rancher_private_ca                = true
  rancher_bootstrap_password_length = 24
  rancher_auth_keycloak_realm       = "company"
  rancher_auth_allowed_group        = "k8s-admins"
  rancher_auth_global_role          = "admin"
  rancher_auth_access_mode          = "restricted"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = "portainer"
      secret_name = local.portainer_tls_secret_name
    },
    {
      certificate = local.default_certificate_name
      namespace   = "cattle-system"
      secret_name = local.rancher_tls_secret_name
    },
  ]
}
