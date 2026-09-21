# Dynamic Grafana provisioning

The monitoring deployment can consume Grafana provisioning resources created by
a later, independent deployment phase. The consumer runs inside the Grafana pod,
watches labeled ConfigMaps across the cluster, writes their data keys to the
appropriate provisioning directory, and hot-reloads Grafana when required.

Enable the consumer with:

```hcl
grafana_dynamic_provisioning_enabled = true
```

## Metadata contract

The sidecars read only the following two metadata keys. All other labels shown
in the examples are inventory metadata and do not affect Grafana provisioning.
`metadata.name` is required by Kubernetes, and `metadata.namespace` determines
where the ConfigMap lives; neither is a Grafana label.

| Metadata key | Kind | Required | Used for |
|---|---|---:|---|
| `grafana/provisioning` | Label | Yes | Selects the ConfigMap and determines which sidecar processes it. |
| `grafana/folder` | Annotation | No | Places dashboards in a folder hierarchy. It is only meaningful when `grafana/provisioning: dashboard`. |

Kubernetes watch selectors can select labels but not annotations. For that
reason, `grafana/provisioning` must be a label. Its accepted values are:

| Label value | ConfigMap data | Reload behavior |
|---|---|---|
| `dashboard` | One Grafana dashboard JSON document per data key | The file provider detects changes and deletions. |
| `datasource` | Grafana data source provisioning YAML or JSON | The sidecar calls the data source provisioning reload API. |
| `alerting` | Grafana Alerting provisioning YAML or JSON | The sidecar calls the alerting provisioning reload API. |

This is the minimum functional metadata for a dashboard:

```yaml
metadata:
  name: application-overview-dashboard
  namespace: example-application
  labels:
    grafana/provisioning: dashboard
```

Add `grafana/folder` only when the dashboard needs a specific destination:

```yaml
metadata:
  annotations:
    grafana/folder: applications/example
```

The following Kubernetes recommended labels are optional for Grafana but should
be added to repository-managed ConfigMaps for ownership and inventory:

| Optional label | Purpose | Example |
|---|---|---|
| `app.kubernetes.io/name` | Concrete configuration or application name. | `application-overview` |
| `app.kubernetes.io/instance` | Deployed instance that owns the configuration. | `application-overview` |
| `app.kubernetes.io/component` | Functional role of the ConfigMap. | `dashboard`, `datasource-provisioning`, or `alerting` |
| `app.kubernetes.io/part-of` | Broader application or system. | `example-application` |
| `app.kubernetes.io/managed-by` | Controller or repository responsible for it. | `infrastructure` |

These ownership labels are ignored by every Grafana sidecar. Changing or
removing them does not change sidecar selection or dashboard placement.

ConfigMaps can live in any namespace. The Grafana provisioning ServiceAccount
has a ClusterRole limited to `get`, `list`, and `watch` on ConfigMaps. It cannot
read Secrets or modify Kubernetes resources.

## Dashboard example

The optional `grafana/folder` annotation is a relative directory.
With `foldersFromFilesStructure` enabled, each directory segment becomes a
Grafana folder. Do not use an absolute path.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: application-overview-dashboard
  namespace: example-application
  labels:
    # Required: selects the dashboard sidecar.
    grafana/provisioning: dashboard
    # Optional for Grafana; recommended ownership and inventory metadata.
    app.kubernetes.io/name: application-overview
    app.kubernetes.io/instance: application-overview
    app.kubernetes.io/component: dashboard
    app.kubernetes.io/part-of: example-application
    app.kubernetes.io/managed-by: infrastructure
  annotations:
    # Optional: creates the applications / example folder hierarchy.
    grafana/folder: applications/example
data:
  application-overview.json: |-
    {
      "uid": "example-application-overview",
      "title": "Example application overview",
      "schemaVersion": 42,
      "panels": []
    }
```

Dashboard data keys should end in `.json`, and each dashboard should define a
stable `uid`. Deleting the ConfigMap removes the corresponding file and, because
the dynamic provider has `disableDeletion: false`, removes the provisioned
dashboard from Grafana.

## Data source example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: application-datasources
  namespace: example-application
  labels:
    # Required: selects the data source sidecar.
    grafana/provisioning: datasource
    # Optional for Grafana; recommended ownership and inventory metadata.
    app.kubernetes.io/name: application-datasources
    app.kubernetes.io/instance: application-datasources
    app.kubernetes.io/component: datasource-provisioning
    app.kubernetes.io/part-of: example-application
    app.kubernetes.io/managed-by: infrastructure
data:
  application-datasources.yaml: |-
    apiVersion: 1
    datasources:
      - name: Application Prometheus
        uid: example-application-prometheus
        type: prometheus
        access: proxy
        url: http://prometheus.example-application.svc.cluster.local:9090
        isDefault: false
```

Use `prune: true` or `deleteDatasources` according to Grafana's provisioning
format when the desired lifecycle includes data source deletion. ConfigMaps are
not suitable for credentials, tokens, or other secrets. This integration
intentionally watches only ConfigMaps; a data source requiring credentials needs
a separately designed secret-delivery mechanism.

## Alerting example

The `alerting` type accepts the complete Grafana Alerting file-provisioning
schema: alert rule groups, contact points, notification policies, mute timings,
and notification templates.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: application-alerts
  namespace: example-application
  labels:
    # Required: selects the alerting sidecar.
    grafana/provisioning: alerting
    # Optional for Grafana; recommended ownership and inventory metadata.
    app.kubernetes.io/name: application-alerts
    app.kubernetes.io/instance: application-alerts
    app.kubernetes.io/component: alerting
    app.kubernetes.io/part-of: example-application
    app.kubernetes.io/managed-by: infrastructure
data:
  application-alerts.yaml: |-
    apiVersion: 1
    groups:
      - orgId: 1
        name: example-application
        folder: Example application
        interval: 1m
        rules: []
```

Removing an alerting file does not implicitly delete previously provisioned
Grafana Alerting objects. Use the corresponding `deleteRules`,
`deleteContactPoints`, `deletePolicies`, or other deletion entries supported by
the Grafana provisioning schema before removing the ConfigMap. File-provisioned
alerting objects are read-only in the Grafana UI.

## Operational notes

- ConfigMap objects are limited to 1 MiB. Split large dashboard collections
  across several ConfigMaps.
- Data-key filenames must be unique across selected ConfigMaps. The sidecar
  prefixes collisions to avoid overwriting another producer's file, but stable,
  descriptive names remain preferable.
- The sidecars use cluster-scoped `get`, `list`, and `watch` permissions for
  ConfigMaps and run with the same non-root pod security context as Grafana.
  Any namespace able to create a ConfigMap with `grafana/provisioning` can
  therefore submit provisioning content to Grafana; namespace write access to
  that label must be treated as Grafana configuration authority.
- Data source and alerting reloads authenticate through files projected from the
  existing `grafana-admin` Secret. The values are not copied into ConfigMaps.
- The sidecar image and resources are controlled by the
  `grafana_provisioning_sidecar_*` settings in `monitoring_constants.tf`.

For the accepted file formats, see the official Grafana documentation for
[provisioning dashboards and data sources](https://grafana.com/docs/grafana/latest/administration/provisioning/)
and [file-provisioned alerting resources](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/).
