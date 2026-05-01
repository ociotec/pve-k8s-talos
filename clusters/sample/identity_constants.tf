locals {
  identity_namespace = "identity"

  keycloak_hostname        = "keycloak.${local.domain}"
  keycloak_tls_secret_name = "keycloak-tls"
  keycloak_image_tag       = "26.6.1"

  keycloak_admin_username        = "admin"
  keycloak_admin_password_length = 24

  keycloak_db_name         = "keycloak"
  keycloak_db_username     = "keycloak"
  postgres_image_tag       = "18.3"
  postgres_pvc_size        = "8Gi"
  postgres_password_length = 24

  postgres_storage_class = "${local.ceph_name_prefix}-rbd-ec"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = local.identity_namespace
      secret_name = local.keycloak_tls_secret_name
    },
  ]
}
