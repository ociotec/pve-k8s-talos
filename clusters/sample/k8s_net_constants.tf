locals {
  domain                  = "home.arpa"

  tls_source              = "ca_issuer"

  # Public CA certificate path. When present, gen-talos-assets installs it into every
  # Talos node as a TrustedRootsConfig. Required for "preissued".
  root_ca_crt             = "./certs/${local.domain}.pem"

  root_ca_common_name     = local.domain
  root_ca_organization    = "My home local network"
  root_ca_validity_hours  = 876000 # 100 years
  root_ca_key             = "./certs/${local.domain}.key"

  metallb_pool_start      = "192.168.1.70"
  metallb_pool_end        = "192.168.1.79"
  ingress_lb_ip           = "192.168.1.70"
  available_certificates  = {
    wildcard_default = {
      cert_path = "./certs/wildcard.${local.domain}.fullchain.pem"
      key_path  = "./certs/wildcard.${local.domain}.key"
    }
  }
  default_certificate_name = "wildcard_default"

  # available_certificates is the catalog of installable certificate/key pairs.
  # Consumers such as monitoring or the Rook dashboard reference them by name.
}
