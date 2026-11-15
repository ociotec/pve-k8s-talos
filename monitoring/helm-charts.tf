locals {
  helm_chart_sources = {
    policy-reporter = {
      enabled    = local.enable_policy_reporter_value
      repository = "oci://ghcr.io/kyverno/charts"
      chart      = "policy-reporter"
      version    = local.policy_reporter_chart_version_value
    }
    grafana = {
      enabled    = local.grafana_helm_enabled_value
      repository = "oci://ghcr.io/grafana-community/helm-charts"
      chart      = "grafana"
      version    = local.grafana_helm_chart_version_value
    }
    grafana-operator = {
      enabled    = local.grafana_operator_enabled_value
      repository = "oci://ghcr.io/grafana/helm-charts"
      chart      = "grafana-operator"
      version    = local.grafana_operator_chart_version_value
    }
    vpa = {
      enabled    = local.enable_vpa_value
      repository = "https://charts.fairwinds.com/stable"
      chart      = "vpa"
      version    = "5.1.0"
    }
  }
  # OpenTofu and the CRD preflight consume the same prepared chart bytes.
  helm_chart_downloads = {
    for name, source in local.helm_chart_sources : name => merge(source, {
      path = "${path.module}/.charts/${name}-${source.version}.tgz"
    })
  }
}
