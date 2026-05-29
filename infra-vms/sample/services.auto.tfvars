services = {
  "docker" = {
    "enabled" = true
    "packages" = [
      "docker.io",
    ]
    # Docker registry mirrors apply to Docker Hub pulls. For other upstreams,
    # point service image names at your internal registry when required.
    "registry_mirrors"    = []
    "insecure_registries" = []
    "registry_auths"      = {}
    "daemon_options"      = {}
  }

  "talos_discovery" = {
    "enabled"     = true
    "image"       = "ghcr.io/siderolabs/discovery-service:v1.0.17"
    "pull_policy" = "missing"
    "grpc_port"   = 3000
    "http_port"   = 3001
    "public_port" = 443
    "server_name" = "talos-discovery.example.com"
    # Prefer a certificate signed by the CA that Talos nodes trust via
    # constants["network"]["cert_files"] in each dependent cluster.
    "tls_cert_path" = ""
    "tls_key_path"  = ""
    "environment"   = {}
  }
}
