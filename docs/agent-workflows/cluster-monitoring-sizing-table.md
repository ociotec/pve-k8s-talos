# Cluster Monitoring Sizing Table Workflow

Use this workflow when the user wants to refresh monitoring sizing values, build a cross-cluster sizing table, or compare current requests, limits, and PVC sizes against real cluster usage.

This workflow is repo-local guidance for agents. It is not a globally installed Codex skill.

## Required Input

One or more real cluster names are required because kubeconfigs, generated workspaces, Prometheus data, and cluster constants are cluster-specific.

If the user does not provide cluster names, ask for them before running commands.

Optional input:

- service scope
  - default: `grafana`, `grafana-postgres`, `prometheus`, and `loki`

## Scope

Build a comparison table for monitoring sizing decisions across one or more real clusters.

Include:

- current CPU requests and limits from repository constants
- current memory requests and limits from repository constants
- current relevant PVC sizes from repository constants
- worker inventory and declared worker capacity from cluster inventory files
- live CPU and memory usage from Prometheus for the selected monitoring services
- proposed new CPU, memory, and PVC values derived from the agreed sizing formulas

Exclude:

- clusters not named by the user unless they are needed to explain an outlier
- deployments, plans, or direct cluster mutations

## Required Behavior

- Use the user's language unless they ask for another language.
- Prefer real clusters named by the user.
- Present the result as a Markdown table.
- Use `CPU 24h p95` and `Memory 24h max` as the live usage columns.
- Never print secrets, authenticated URLs, or raw credentials from OpenTofu state.
- Never mutate the cluster from this workflow.
- Never run `tofu plan`, `tofu apply`, or any deployment script from this workflow.
- Only inspect cluster state and repository files unless the user explicitly asks for follow-up edits.
- If repository files are later changed from this analysis, end the response with the minimal `scripts/deploy.sh` command needed to apply the change. The user runs it manually.

## Output Format

Use this column set unless the user requests a different shape:

| Cluster | Service | CPU 24h p95 | Current CPU request | Proposed CPU request | Current CPU limit | Proposed CPU limit | Memory 24h max | Current memory request | Proposed memory request | Current memory limit | Proposed memory limit | Current PVC size | Proposed PVC size |

Column rules:

- `Cluster`: cluster directory name.
- `Service`: one of the selected monitoring services, by default `grafana`, `grafana-postgres`, `prometheus`, or `loki`.
- `CPU 24h p95`: 95th percentile CPU usage over the last 24 hours for the current live pod and target container.
- `Current CPU request`: current CPU request from repository constants.
- `Proposed CPU request`: proposed CPU request after formula and rounding.
- `Current CPU limit`: current CPU limit from repository constants.
- `Proposed CPU limit`: proposed CPU limit after formula and rounding.
- `Memory 24h max`: maximum working-set memory over the last 24 hours for the current live pod and target container.
- `Current memory request`: current memory request from repository constants.
- `Proposed memory request`: proposed memory request after formula and rounding.
- `Current memory limit`: current memory limit from repository constants.
- `Proposed memory limit`: proposed memory limit after formula and rounding.
- `Current PVC size`: current relevant PVC size from repository constants, when the service has one.
- `Proposed PVC size`: proposed relevant PVC size after formula, human-friendly unit rendering, and the no-shrink safety rule for existing clusters.

If a service has no relevant PVC, render `n/a` in both PVC columns.

## Formula And Rounding Rules

Use the currently agreed monitoring sizing assumptions:

- Grafana auto-scales CPU and memory.
- Loki auto-scales memory and PVC, with softened growth for larger clusters.
- Prometheus auto-scales CPU, memory, and PVC.
- Existing cluster PVCs must never shrink.

Required rules:

- CPU rounds up to the next `10m`.
- Prometheus CPU request: `ceil(300m * prometheus_sizing_factor / 10m) * 10m`.
- Prometheus CPU limit: `ceil(max(1500m, 1000m * prometheus_sizing_factor) / 10m) * 10m`.
- Memory rounds up to the next `64Mi`.
- Prefer whole `Gi` when the rounded result is exact or intentionally rounded to a clean Gi.
- Use human-friendly `Gi` for PVCs whenever practical.
- Existing PVC safety rule:
  - `effective_pvc_size = max(current_configured_size, formula_size)`

When rendering values:

- write integer CPU values in Kubernetes-canonical core form, for example `1` or `2`
- keep non-integer CPU values in millicores, for example `890m` or `1500m`
- write whole-Gi memory values in `Gi`
- keep non-whole Gi memory values in `Mi`

## Workflow

1. Identify the target cluster directories:
   - `clusters/<cluster>/`
2. Read current monitoring constants from:
   - `clusters/<cluster>/monitoring_constants.tf`
   - optionally `clusters/<cluster>/identity_constants.tf` if the requested scope later extends beyond the default monitoring services
3. Read worker inventory and declared worker capacity from:
   - `clusters/<cluster>/vms.auto.tfvars`
   - `clusters/<cluster>/resources.auto.tfvars`
4. Confirm repo-stamp status for each real cluster:
   - inspect `clusters/<cluster>/.repo-status.json`
   - compare its `repo_commit` with `git rev-parse HEAD`
   - if the stamp differs, follow the drift rules from `AGENTS.md`
5. Resolve the live monitoring pods:
   - run from `clusters/<cluster>`
   - use `direnv exec . kubectl -n monitoring get pods -o custom-columns=NAME:.metadata.name,APP:.metadata.labels.app --no-headers`
   - map service names to current pods
6. Fetch live usage metrics from Prometheus:
   - prefer `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig -n monitoring port-forward svc/prometheus <local-port>:9090` when direct `prometheus-api` TLS or auth is awkward
   - do not print secrets or authenticated URLs
7. Query Prometheus for each target service pod and container using these patterns:
   - CPU:
     `quantile_over_time(0.95, (sum(rate(container_cpu_usage_seconds_total{namespace="monitoring",pod="<pod>",container="<container>",image!=""}[5m])))[24h:5m])`
   - RAM:
     `max_over_time((sum(container_memory_working_set_bytes{namespace="monitoring",pod="<pod>",container="<container>",image!=""}))[24h:5m])`
8. Compute proposed new values from the agreed formulas:
   - derive `worker_count`
   - derive total worker CPU and RAM from inventory files
   - apply the current Grafana, Prometheus, and softened Loki sizing assumptions
9. Apply the PVC no-shrink rule for existing clusters:
   - `effective_pvc_size = max(current_configured_size, formula_size)`
10. Render the final Markdown table with the required columns.
11. If a cluster shows an unexpected outlier, call it out briefly below the table.
12. If repository files are later changed from this analysis:
   - validate only the affected generated workspaces
   - do not deploy
   - end with the minimal `scripts/deploy.sh` command that the user should run manually

## Validation Expectations

When the workflow is used to refresh current planning inputs, confirm that it reproduces:

- current live usage columns using `CPU 24h p95` and `Memory 24h max`
- non-shrinking PVC outputs for existing clusters
- cleaned human-readable PVC units such as `103Gi` and `104Gi`

## Notes

- This workflow is for planning, comparison, and audit work, not deployment.
- If Prometheus lacks the full 24-hour window, use the longest available range and state the effective range.
- If a service pod has rolled recently, use the current live pod for the metric query and note that the usage window may span a previous pod incarnation only if that materially affects interpretation.

## How To Invoke

Typical user requests that should trigger this workflow:

- `Refresh monitoring sizing values for these clusters`
- `Build a cross-cluster monitoring sizing table`
- `Compare monitoring requests, limits, and PVC sizes against real usage`
- `Show Grafana, Prometheus, and Loki sizing across these clusters`
- `Follow docs/agent-workflows/cluster-monitoring-sizing-table.md for these clusters`
