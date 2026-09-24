# Grafana Operator resource provisioning

Grafana Operator is installed by the monitoring section and watches Grafana
custom resources in every namespace. The platform registers the Helm-managed
Grafana service as `Grafana/monitoring/grafana-primary` with this label:

```yaml
grafana/instance: primary
```

Application and platform charts can therefore declare Grafana resources in
their own namespaces. The operator selects `grafana-primary`, calls the Grafana
API, and records reconciliation state on the custom resource. It does not own
the Grafana Deployment, Service, PostgreSQL database, or PVCs.

The examples below target the `v1beta1` CRDs installed with Grafana Operator
5.25.0. Consult the [official API reference](https://grafana.github.io/grafana-operator/docs/api/)
when using fields not covered here.

## Ownership model

Keep the ownership boundary explicit:

```text
Helm or OpenTofu             Grafana Operator
-------------------------   ---------------------------------
owns Kubernetes CRs         owns the corresponding Grafana entities
creates/updates/deletes CR  reconciles through the Grafana HTTP API
```

Do not manage the same Grafana UID through both an operator CR and another
mechanism such as the repository dashboard-sync Job, a provisioning file, or
manual API automation. Migrate one entity at a time and remove its old owner
only after the CR reports a successful reconciliation.

The application chart should contain its namespaced CRs. It must not install
the Grafana Operator CRDs; those belong to the monitoring release.

## Common targeting rules

Every resource intended for the platform Grafana uses this selector:

```yaml
spec:
  instanceSelector:
    matchLabels:
      grafana/instance: primary
```

The registered Grafana object is in `monitoring`. A resource created in any
other namespace must also set:

```yaml
spec:
  allowCrossNamespaceImport: true
```

`allowCrossNamespaceImport` belongs to each `GrafanaFolder`,
`GrafanaDatasource`, `GrafanaDashboard`, or `GrafanaAlertRuleGroup`; it is not
a setting on `Grafana/grafana-primary`. It is intentionally disabled by
default. Once enabled, disabling it requires deleting and recreating the CR so
the operator can perform deterministic cleanup.

The resource's `instanceSelector` and most UID/reference fields are immutable.
Changing them may also require recreation. Review the server validation error
before replacing an existing resource.

## Complete example

This example can be included in an application Helm chart. Replace
`example-app`, names, URLs, alert queries, and labels with
application-specific values. The dashboard content remains in a separate JSON
file, as described below. Stable UIDs allow dashboards and alert rules to
refer to resources without depending on Grafana-generated identifiers.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: example-observability
  namespace: example-app
  labels:
    app.kubernetes.io/name: example-observability
    app.kubernetes.io/instance: example-app
    app.kubernetes.io/component: folder
    app.kubernetes.io/part-of: example-app
    app.kubernetes.io/managed-by: Helm
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      grafana/instance: primary
  uid: example-observability
  title: Example application
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: example-prometheus
  namespace: example-app
  labels:
    app.kubernetes.io/name: example-observability
    app.kubernetes.io/instance: example-app
    app.kubernetes.io/component: datasource
    app.kubernetes.io/part-of: example-app
    app.kubernetes.io/managed-by: Helm
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      grafana/instance: primary
  uid: example-prometheus
  datasource:
    name: Example Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.monitoring.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 30s
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: example-availability
  namespace: example-app
  labels:
    app.kubernetes.io/name: example-observability
    app.kubernetes.io/instance: example-app
    app.kubernetes.io/component: dashboard
    app.kubernetes.io/part-of: example-app
    app.kubernetes.io/managed-by: Helm
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      grafana/instance: primary
  uid: example-availability
  folderRef: example-observability
  configMapRef:
    name: example-availability-dashboard
    key: dashboard.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaAlertRuleGroup
metadata:
  name: example-availability
  namespace: example-app
  labels:
    app.kubernetes.io/name: example-observability
    app.kubernetes.io/instance: example-app
    app.kubernetes.io/component: alerting
    app.kubernetes.io/part-of: example-app
    app.kubernetes.io/managed-by: Helm
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      grafana/instance: primary
  folderRef: example-observability
  name: Example application availability
  interval: 1m
  rules:
    - uid: example-target-down
      title: Example target is down
      condition: C
      for: 5m
      noDataState: NoData
      execErrState: Error
      isPaused: false
      annotations:
        description: The example target has been unavailable for five minutes.
        summary: Example target is down
      labels:
        severity: warning
        service: example-app
      data:
        - refId: A
          datasourceUid: example-prometheus
          relativeTimeRange:
            from: 600
            to: 0
          model:
            datasource:
              type: prometheus
              uid: example-prometheus
            editorMode: code
            expr: min(up)
            instant: true
            intervalMs: 1000
            maxDataPoints: 43200
            refId: A
        - refId: B
          datasourceUid: __expr__
          relativeTimeRange:
            from: 0
            to: 0
          model:
            conditions: []
            datasource:
              type: __expr__
              uid: __expr__
            expression: A
            intervalMs: 1000
            maxDataPoints: 43200
            reducer: last
            refId: B
            type: reduce
        - refId: C
          datasourceUid: __expr__
          relativeTimeRange:
            from: 0
            to: 0
          model:
            conditions:
              - evaluator:
                  params: [1]
                  type: lt
                operator:
                  type: and
                query:
                  params: [C]
                reducer:
                  params: []
                  type: last
                type: query
            datasource:
              type: __expr__
              uid: __expr__
            expression: B
            intervalMs: 1000
            maxDataPoints: 43200
            refId: C
            type: threshold
```

`folderRef` refers to a `GrafanaFolder` CR in the same Kubernetes namespace.
Prefer it over a generated Grafana folder identifier. Set a stable
`GrafanaFolder.spec.uid`; otherwise adopting a pre-existing folder with the
same title can be ambiguous.

`datasourceUid` must equal the stable `GrafanaDatasource.spec.uid`. The
`__expr__` datasource is Grafana's built-in server-side expression engine.
Grafana Operator manages Grafana-managed alerts; it does not deploy Prometheus
rule files.

## Dashboard JSON in a separate file

Keep dashboard JSON outside Kubernetes templates so it can be edited,
formatted, generated, and reviewed independently:

```text
example-chart/
├── dashboards/
│   └── example-availability.json
└── templates/
    ├── grafana-dashboard-content.yaml
    └── grafana-dashboard.yaml
```

`templates/grafana-dashboard-content.yaml` packages the file in a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-availability-dashboard
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: example-observability
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: dashboard
    app.kubernetes.io/part-of: example-app
    app.kubernetes.io/managed-by: {{ .Release.Service }}
data:
  dashboard.json: |-
{{ .Files.Get "dashboards/example-availability.json" | nindent 4 }}
```

The `GrafanaDashboard` from the complete example contains only the reference:

```yaml
spec:
  uid: example-availability
  folderRef: example-observability
  configMapRef:
    name: example-availability-dashboard
    key: dashboard.json
```

The ConfigMap and `GrafanaDashboard` must be in the same Kubernetes namespace.
The ConfigMap key contains the complete Grafana dashboard model; its internal
content is deliberately outside the CR and this guide. `spec.uid` provides the
stable Grafana UID and overrides a UID contained in the JSON model.

ConfigMaps are limited to 1 MiB. For unusually large dashboards, use another
supported content source such as an OCI artifact instead of splitting one
dashboard across unrelated CRs.

## Datasource credentials

Never put credentials directly in `spec.datasource`, chart values, or the
repository. Store them in a Secret in the same namespace as the
`GrafanaDatasource`, then inject them with `valuesFrom`:

```yaml
spec:
  valuesFrom:
    - targetPath: secureJsonData.httpHeaderValue1
      valueFrom:
        secretKeyRef:
          name: example-prometheus-credentials
          key: BEARER_TOKEN
  datasource:
    name: Example Prometheus
    type: prometheus
    access: proxy
    url: https://prometheus.example.com
    jsonData:
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: Bearer ${BEARER_TOKEN}
```

The substitution token must match the referenced Secret key. The operator
reads the Secret from the CR's namespace. Use the cluster's approved secret
delivery mechanism rather than committing a Secret containing a real value.

Grafana is registered as an external instance, so datasource `plugins` cannot
install plugins into its container. Add required plugins to the Grafana Helm
workload instead.

## Helm packaging and ordering

Recommended chart layout:

```text
dashboards/
└── example-availability.json
templates/
├── grafana-folder.yaml
├── grafana-datasource.yaml
├── grafana-dashboard-content.yaml
├── grafana-dashboard.yaml
└── grafana-alert-rule-group.yaml
```

Use Helm release ownership labels and keep stable `metadata.name` and
`spec.uid` values. Kubernetes creation order is not a readiness guarantee: the
operator may initially report a missing folder or datasource and reconcile
again after the dependency becomes available.

When removing a chart:

1. Keep Grafana and Grafana Operator running.
2. Delete the application CRs through Helm.
3. Wait until their finalizers have completed.
4. Only then remove the Operator or the registered Grafana instance.

Do not use Helm's resource retention annotation on these CRs unless leaving
the corresponding Grafana entities behind is explicitly intended.

## RBAC for application teams

Creating a CR also requires Kubernetes RBAC in its namespace. A minimal Role
for the four resource types is:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: grafana-resource-editor
  namespace: example-app
rules:
  - apiGroups: [grafana.integreatly.org]
    resources:
      - grafanafolders
      - grafanadatasources
      - grafanadashboards
      - grafanaalertrulegroups
    verbs: [create, get, list, watch, patch, update, delete]
```

Grant Secret access separately and only where operationally required. Creating
a datasource that references an existing Secret does not require the chart
author to read or print that Secret.

## Validation and troubleshooting

Validate rendered Helm output against the installed CRD schemas before
installing it:

```bash
helm template example-app ./chart |
  kubectl apply --dry-run=server -f -
```

Inspect reconciliation without displaying Secret data:

```bash
kubectl get grafanafolders,grafanadatasources,grafanadashboards,grafanaalertrulegroups -A
kubectl -n example-app get grafanadashboard example-availability -o yaml
kubectl -n example-app describe grafanaalertrulegroup example-availability
kubectl -n monitoring logs deployment/grafana-operator --since=10m
```

Check `.status` for the matched Grafana instance, last synchronization time,
and reconciliation errors. A CR that remains without a matching instance most
commonly has a wrong selector or is missing `allowCrossNamespaceImport: true`.

Deletion is asynchronous. The operator finalizer deletes the remote Grafana
entity before Kubernetes removes the CR:

```bash
kubectl -n example-app delete grafanadashboard example-availability
kubectl -n example-app get grafanadashboard example-availability -o yaml
```

Do not manually remove finalizers during normal operation. Doing so abandons
the remote Grafana entity. Manual finalizer removal is only a disaster-recovery
action after confirming that the Operator or Grafana cannot be restored.

## Further reference

- [Common options and cross-namespace imports](https://grafana.github.io/grafana-operator/docs/examples/common_options/)
- [Dashboards](https://grafana.github.io/grafana-operator/docs/examples/dashboard/)
- [Datasources and secret substitution](https://grafana.github.io/grafana-operator/docs/examples/datasource/)
- [Folders](https://grafana.github.io/grafana-operator/docs/examples/folder/)
- [Alert rule groups](https://grafana.github.io/grafana-operator/docs/examples/alertrulegroup/full-notification-configuration/)
