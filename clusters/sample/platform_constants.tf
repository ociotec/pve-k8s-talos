locals {
  portainer_hostname        = "portainer.${local.domain}"
  portainer_tls_secret_name = "portainer-tls"

  storage_class = "${local.ceph_name_prefix}-rbd-ec"

  portainer_image_tag     = "2.40.0"
  portainer_storage_class = local.storage_class
  portainer_pvc_size      = "10Gi"

  tls_secrets = [
    {
      certificate = local.default_certificate_name
      namespace   = "portainer"
      secret_name = local.portainer_tls_secret_name
    },
  ]
}
