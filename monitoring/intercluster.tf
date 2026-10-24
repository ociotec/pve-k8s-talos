# Optional locals are supplied by prepare-monitoring-defaults.py for clusters
# that do not declare them. No remote cluster or remote state is queried here.
locals {
  monitoring_query_exports_enabled = length(local.monitoring_api_consumers) > 0
  grafana_remote_enabled           = length(local.grafana_remote_clusters) > 0
  monitoring_query_enabled         = local.monitoring_query_exports_enabled || local.grafana_remote_enabled
  monitoring_query_labels = {
    "app.kubernetes.io/name"       = "monitoring-query-api"
    "app.kubernetes.io/instance"   = "monitoring-query-api"
    "app.kubernetes.io/component"  = "query-gateway"
    "app.kubernetes.io/part-of"    = "monitoring"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "monitoring"
  }
  monitoring_query_services = {
    prometheus = { port = 9090, title = "Prometheus", uid = "PBFA97CFB590B2093" }
    loki       = { port = 3100, title = "Loki", uid = "P8E80F9AEF21F6940" }
    tempo      = { port = 3200, title = "Tempo", uid = "P214B5B846CF3925F" }
  }
  grafana_remote_labels = merge(local.monitoring_query_labels, {
    "app.kubernetes.io/name"      = "grafana"
    "app.kubernetes.io/instance"  = "grafana"
    "app.kubernetes.io/component" = "datasource"
    "app.kubernetes.io/part-of"   = "grafana"
  })
  monitoring_query_readers = {
    for consumer in local.monitoring_api_consumers : consumer =>
    try(local.monitoring_credentials.intercluster_readers[consumer], {})
  }
  monitoring_query_auth = join("\n", [
    for consumer in sort(keys(local.monitoring_query_readers)) :
    format("%s:%s", try(local.monitoring_query_readers[consumer].username, ""), try(local.monitoring_query_readers[consumer].htpasswd, ""))
  ])
  grafana_local_datasources = [for service, config in local.monitoring_query_services : merge({
    name      = trimspace("${config.title} ${local.grafana_datasource_suffix}")
    type      = service
    access    = "proxy"
    url       = "http://${service}.monitoring.svc.cluster.local:${config.port}"
    isDefault = service == "prometheus"
    }, trimspace(local.grafana_datasource_suffix) != "" ? {
    # These are the existing Grafana-generated UIDs. Never rename by name alone:
    # provisioning would create duplicates and break dashboard references.
    uid = config.uid
    } : {}, jsondecode(service == "tempo" && trimspace(local.grafana_datasource_suffix) != "" ? jsonencode({
      jsonData = {
        tracesToLogsV2  = { datasourceUid = local.monitoring_query_services.loki.uid, filterByTraceID = true }
        tracesToMetrics = { datasourceUid = local.monitoring_query_services.prometheus.uid }
        serviceMap      = { datasourceUid = local.monitoring_query_services.prometheus.uid }
      }
  }) : "{}"))]
  grafana_remote_sources = merge({}, [for cluster, config in local.grafana_remote_clusters : {
    for service, definition in local.monitoring_query_services : "${cluster}-${service}" => {
      cluster = cluster
      service = service
      name    = trimspace("${definition.title} ${config.datasource_suffix}")
      url     = config["${service}_url"]
    }
  }]...)
  grafana_postgres_init_command = ["sh", trimspace(local.grafana_datasource_suffix) == "" ? "-c" : "-ec", join("\n", compact([
    "until pg_isready -h grafana-postgres -p 5432 -U \"$POSTGRES_USER\"; do sleep 5; done",
    trimspace(local.grafana_datasource_suffix) == "" ? "" : join("\n", [
      "psql -h grafana-postgres -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -v ON_ERROR_STOP=1 <<'SQL'",
      templatefile("${path.module}/grafana/rename-local-datasources.sql.tftpl", { datasources = local.grafana_local_datasources }),
      "SQL",
    ]),
  ]))]
  grafana_postgres_migration_env = trimspace(local.grafana_datasource_suffix) == "" ? [] : [
    { name = "POSTGRES_DB", valueFrom = { secretKeyRef = { name = "grafana-db", key = "database" } } },
    { name = "PGPASSWORD", valueFrom = { secretKeyRef = { name = "grafana-db", key = "password" } } },
  ]
  grafana_remote_secrets = {
    for cluster, config in local.grafana_remote_clusters : cluster => {
      name     = config.credentials_secret_ref
      username = try(local.monitoring_credentials.remote_clusters[cluster].username, "")
      password = try(local.monitoring_credentials.remote_clusters[cluster].password, "")
      ca       = try(file(config.ca_file), "")
    }
  }
  monitoring_query_probe = {
    httpGet          = { path = "/healthz", port = "health", scheme = "HTTP" }
    timeoutSeconds   = 1
    successThreshold = 1
    periodSeconds    = 10
    failureThreshold = 3
  }
  monitoring_query_manifests = {
    config = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "monitoring-query-api", namespace = "monitoring", labels = local.monitoring_query_labels }
      data       = { "nginx.conf" = file("${path.module}/query-api.conf") }
    }
    service = {
      apiVersion = "v1"
      kind       = "Service"
      metadata   = { name = "monitoring-query-api", namespace = "monitoring", labels = local.monitoring_query_labels }
      spec = {
        selector = { "app.kubernetes.io/name" = "monitoring-query-api" }
        ports = concat([{ name = "grafana", port = 3000, targetPort = "grafana" }], [
          for service, config in local.monitoring_query_services : { name = service, port = config.port, targetPort = service }
        ])
      }
    }
    deployment = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata   = { name = "monitoring-query-api", namespace = "monitoring", labels = local.monitoring_query_labels }
      spec = {
        replicas = 1
        selector = { matchLabels = { "app.kubernetes.io/name" = "monitoring-query-api" } }
        template = {
          metadata = {
            labels      = local.monitoring_query_labels
            annotations = { "checksum/config" = filesha256("${path.module}/query-api.conf") }
          }
          spec = {
            priorityClassName = "infra-observability"
            containers = [{
              name = "nginx"
              # Official multi-architecture image, pinned independently of the moving tag.
              image   = try(local.monitoring_query_api.image, "docker.io/nginx:stable-alpine@sha256:47928bf67eb62a1863cb08d9ecb52d3e704304ba614eaee17884204677702951")
              command = ["nginx", "-g", "daemon off;"]
              ports = concat([{ name = "health", containerPort = 8080 }, { name = "grafana", containerPort = 3000 }], [
                for service, config in local.monitoring_query_services : { name = service, containerPort = config.port }
              ])
              resources = {
                requests = { cpu = try(local.monitoring_query_api.cpu_request, "20m"), memory = try(local.monitoring_query_api.memory, "64Mi") }
                limits   = { cpu = try(local.monitoring_query_api.cpu_limit, "200m"), memory = try(local.monitoring_query_api.memory, "64Mi") }
              }
              readinessProbe = local.monitoring_query_probe
              livenessProbe  = local.monitoring_query_probe
              volumeMounts = [
                { name = "config", mountPath = "/etc/nginx/nginx.conf", subPath = "nginx.conf", readOnly = true },
                { name = "tmp", mountPath = "/tmp" },
              ]
              securityContext = {
                runAsUser                = 101
                runAsGroup               = 101
                runAsNonRoot             = true
                readOnlyRootFilesystem   = true
                allowPrivilegeEscalation = false
                capabilities             = { drop = ["ALL"] }
              }
            }]
            securityContext = { fsGroup = 101, seccompProfile = { type = "RuntimeDefault" } }
            volumes = [
              { name = "config", configMap = { name = "monitoring-query-api" } },
              { name = "tmp", emptyDir = {} },
            ]
          }
        }
      }
    }
  }
}

# Preconditions fail before creating resources. They check local configuration
# only: a peer may be offline, have no DNS entry, or not exist yet.
resource "terraform_data" "monitoring_intercluster_configuration" {
  lifecycle {
    precondition {
      condition = alltrue([for consumer, credentials in local.monitoring_query_readers :
        can(regex("^[a-zA-Z0-9_-]+$", try(credentials.username, ""))) &&
        try(credentials.username, "") != "prometheus-external" &&
        can(regex("^\\$apr1\\$[^\\r\\n:]+$", try(credentials.htpasswd, "")))
      ])
      error_message = "Each monitoring_api_consumers entry needs username and htpasswd in monitoring.intercluster_readers in credentials.json."
    }
    precondition {
      condition     = length(distinct([for reader in values(local.monitoring_query_readers) : try(reader.username, "")])) == length(local.monitoring_query_readers)
      error_message = "Monitoring API consumer usernames must be unique."
    }
    precondition {
      condition = length(local.grafana_remote_clusters) == 0 || (
        local.grafana_operator_enabled_value && local.grafana_operator_register_existing_instance_value
      )
      error_message = "Remote datasources require Grafana Operator and registration of the existing Grafana instance."
    }
    precondition {
      condition = alltrue([for cluster, config in local.grafana_remote_clusters :
        trimspace(config.datasource_suffix) != "" &&
        trimspace(local.grafana_datasource_suffix) != "" &&
        trimspace(local.grafana_remote_secrets[cluster].username) != "" &&
        trimspace(local.grafana_remote_secrets[cluster].password) != "" &&
        trimspace(local.grafana_remote_secrets[cluster].ca) != ""
      ])
      error_message = "Remote clusters need distinct suffixes, local credentials in monitoring.remote_clusters, and a readable CA file."
    }
    precondition {
      condition     = length(distinct(concat([trimspace(local.grafana_datasource_suffix)], [for peer in values(local.grafana_remote_clusters) : trimspace(peer.datasource_suffix)]))) == length(local.grafana_remote_clusters) + 1
      error_message = "Local and remote datasource suffixes must be unique."
    }
    precondition {
      condition = alltrue([for source in values(local.grafana_remote_sources) :
        can(regex("^https://[^/@?#]+/?$", source.url))
      ])
      error_message = "Remote URLs must be HTTPS base URLs."
    }
    precondition {
      condition     = length(distinct([for peer in values(local.grafana_remote_clusters) : peer.credentials_secret_ref])) == length(local.grafana_remote_clusters)
      error_message = "Each remote cluster must use its own credentials_secret_ref."
    }
  }
}

resource "random_id" "grafana_remote_datasource_uid" {
  # Identity is the cluster/service pair, independent of names, URLs and auth.
  # No keepers: configuration edits must not replace an established UID.
  for_each    = local.grafana_remote_sources
  byte_length = 12
  depends_on  = [terraform_data.monitoring_intercluster_configuration]
}

resource "kubernetes_secret_v1" "monitoring_query_readers" {
  count = local.monitoring_query_exports_enabled ? 1 : 0
  metadata {
    name      = "monitoring-query-readers"
    namespace = "monitoring"
    labels    = local.monitoring_query_labels
  }
  data       = { auth = local.monitoring_query_auth }
  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace, terraform_data.monitoring_intercluster_configuration]
}

resource "kubernetes_manifest" "monitoring_query_api" {
  for_each = { for name, manifest in local.monitoring_query_manifests : name => manifest if local.monitoring_query_enabled }
  manifest = each.value
  # Rancher maintains publicEndpoints on Deployments when ingress paths change.
  computed_fields = ["metadata.annotations"]
  lifecycle {
    ignore_changes = [manifest.metadata.annotations, object.metadata.annotations]
  }
  depends_on = [kubernetes_manifest.monitoring_namespace, terraform_data.monitoring_intercluster_configuration]
}

resource "kubernetes_manifest" "monitoring_query_ingress" {
  for_each = local.monitoring_query_exports_enabled ? { for service in ["loki", "tempo"] : service => local.monitoring_query_services[service] } : {}
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "${each.key}-api"
      namespace = "monitoring"
      labels    = local.monitoring_query_labels
      annotations = {
        "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
        "nginx.ingress.kubernetes.io/auth-type"    = "basic"
        "nginx.ingress.kubernetes.io/auth-secret"  = "monitoring-query-readers"
        "nginx.ingress.kubernetes.io/auth-realm"   = "monitoring-query"
      }
    }
    spec = {
      ingressClassName = "nginx"
      # Reuse the monitoring certificate catalog binding; no new CA or issuer.
      tls = [{ hosts = ["${each.key}-api.${local.domain}"], secretName = local.prometheus_api_tls_secret_name_value }]
      rules = [{ host = "${each.key}-api.${local.domain}", http = { paths = [{
        path     = "/"
        pathType = "Prefix"
        backend  = { service = { name = "monitoring-query-api", port = { number = each.value.port } } }
      }] } }]
    }
  }
  depends_on = [
    kubernetes_manifest.monitoring_query_api, kubernetes_secret_v1.monitoring_query_readers,
    kubernetes_secret_v1.preissued_tls, kubernetes_manifest.monitoring_certificates,
    null_resource.ingress_nginx_webhook_ready,
  ]
}

resource "kubernetes_secret_v1" "grafana_remote" {
  for_each = local.grafana_remote_secrets
  metadata {
    name      = each.value.name
    namespace = "monitoring"
    labels    = local.grafana_remote_labels
  }
  data       = { username = each.value.username, password = each.value.password, ca = each.value.ca }
  type       = "Opaque"
  depends_on = [kubernetes_manifest.monitoring_namespace, terraform_data.monitoring_intercluster_configuration]
}

resource "kubernetes_manifest" "grafana_remote_datasource" {
  for_each = local.grafana_remote_sources
  manifest = {
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaDatasource"
    metadata   = { name = each.key, namespace = "monitoring", labels = local.grafana_remote_labels }
    spec = {
      uid              = random_id.grafana_remote_datasource_uid[each.key].hex
      resyncPeriod     = "5m"
      instanceSelector = { matchLabels = { "grafana/instance" = "primary" } }
      datasource = {
        name          = each.value.name
        type          = each.value.service
        access        = "proxy"
        url           = each.value.url
        basicAuth     = true
        basicAuthUser = "$${username}"
        editable      = false
        isDefault     = false
        secureJsonData = {
          basicAuthPassword = "$${password}"
          tlsCACert         = "$${ca}"
        }
        # Branch on serialized JSON to avoid coercing filterByTraceID into a
        # string while unifying the different nested correlation object types.
        # Normalize this unstructured field, while keeping the manifest identity
        # known during the first plan when random datasource UIDs are unknown.
        jsonData = jsondecode(jsonencode(merge({ tlsAuthWithCACert = true, tlsSkipVerify = false, timeout = 30 }, jsondecode(each.value.service == "tempo" ? jsonencode({
          tracesToLogsV2  = { datasourceUid = random_id.grafana_remote_datasource_uid["${each.value.cluster}-loki"].hex, filterByTraceID = true }
          tracesToMetrics = { datasourceUid = random_id.grafana_remote_datasource_uid["${each.value.cluster}-prometheus"].hex }
          serviceMap      = { datasourceUid = random_id.grafana_remote_datasource_uid["${each.value.cluster}-prometheus"].hex }
        }) : "{}"))))
      }
      valuesFrom = [for field, key in { basicAuthUser = "username", "secureJsonData.basicAuthPassword" = "password", "secureJsonData.tlsCACert" = "ca" } : {
        targetPath = field
        valueFrom  = { secretKeyRef = { name = local.grafana_remote_secrets[each.value.cluster].name, key = key } }
      }]
    }
  }
  # Applying a datasource CR only configures the local Grafana. Its remote
  # health is deliberately not a deployment readiness condition.
  depends_on = [helm_release.grafana_operator, kubernetes_secret_v1.grafana_remote]
}
