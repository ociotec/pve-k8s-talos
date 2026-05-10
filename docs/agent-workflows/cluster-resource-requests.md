# Cluster Resource Requests Workflow

Use this workflow when the user wants to audit Kubernetes CPU and memory requests/limits against real cluster usage for a repository cluster.

This workflow is repo-local guidance for agents. It is not a globally installed Codex skill.

## Required Input

The cluster name is required because kubeconfigs, generated workspaces, Prometheus endpoints, and cluster constants are cluster-specific.

If the user does not provide a cluster name, ask for it before running commands.

## Scope

Audit running Kubernetes workload containers for missing or undersized resource requests and limits.

Include:

- Deployments, StatefulSets, DaemonSets, Jobs, and CronJobs.
- Init containers when they define resources or have recent usage data.
- All namespaces unless the user requests a narrower scope.
- Actual CPU and memory usage over the last 24 hours from Prometheus.

Exclude:

- Standalone Jobs, because this repository treats them as installation or bootstrap one-shots.
- Ephemeral debug containers unless the user explicitly asks for them.
- Static mirror pods when no owning workload can be resolved.

## Required Behavior

- Use the user's language unless they ask for another language.
- Present the result as a Markdown table.
- Prefer invoking `scripts/audit-cluster-resources.sh` instead of manually chaining `kubectl`, `curl`, `jq`, and Prometheus queries.
- Unless the user asks for a narrower report, run the complete audit with Prometheus and include OK containers:
  `../../scripts/audit-cluster-resources.sh --cluster <cluster> --include-ok --all`
- Always show workloads with missing CPU or memory requests first.
- Treat requests as the capacity reservation baseline and limits as the enforcement ceiling.
- Compare reserved resources with actual 24-hour usage, not only current usage.
- Call out when cluster-level used CPU or memory exceeds requested CPU or memory because that indicates under-requested workloads.
- Do not change manifests unless the user explicitly asks for remediation.
- Never apply changes to the cluster from this workflow.
- Never run `tofu plan`, `tofu apply`, or any deployment script from this workflow.
- Only inspect, edit repository files when requested, and run validation commands such as `tofu init` and `tofu validate`.
- After any remediation analysis or file changes, always end the response by showing the minimal `scripts/deploy.sh` command needed to apply the changes, using skip flags for unaffected stacks. The user runs it manually.
- Do not include secrets, private hostnames, private IPs, or raw private URLs in the final answer.

## Output Format

Use this column set unless the user requests a different shape:

| Section | Namespace | Workload | Container | CPU request | CPU limit | CPU 24h p95 | CPU request ratio | Memory request | Memory limit | Memory 24h max | Memory request ratio | Finding | Recommendation |

Column rules:

- `Section`: repository/deployment area affected, such as `identity`, `k8s-net`, `monitoring`, `platform`, `rook`, or `other`.
- `Namespace`: Kubernetes namespace.
- `Workload`: `<kind>/<name>`, for example `Deployment/grafana`.
- `Container`: container name; prefix init containers with `init:`.
- `CPU request`: render in cores or millicores using Kubernetes-style units.
- `CPU limit`: render in cores or millicores; use `missing` when unset.
- `CPU 24h p95`: 95th percentile CPU usage over the last 24 hours.
- `CPU request ratio`: `CPU 24h p95 / CPU request`; use `n/a` when request is missing.
- `Memory request`: render in `Mi` or `Gi`.
- `Memory limit`: render in `Mi` or `Gi`; use `missing` when unset.
- `Memory 24h max`: maximum working-set memory over the last 24 hours.
- `Memory request ratio`: `Memory 24h max / Memory request`; use `n/a` when request is missing.
- `Finding`: concise issue such as `missing requests`, `missing limits`, `CPU request below p95`, `memory request below max`, or `ok`.
- `Recommendation`: concise next action, such as `set CPU and memory requests`, `raise memory request`, `review limit`, or `no change`.

Sort rows by severity:

1. Section.
2. Namespace.
3. Workload.
4. Container.

If the result is large, show the worst 25 rows and state that the table is truncated.

## Workflow

1. Identify the cluster directory:
   - `clusters/<cluster>/`
   - kubeconfig: `clusters/<cluster>/out/kubeconfig`
2. Run the repo script from `clusters/<cluster>`:
   - Default: `../../scripts/audit-cluster-resources.sh --cluster <cluster> --include-ok --all`
   - Use `--top <n>` only when the user asks for a truncated report.
   - Use one or more `--section <name>` flags when the user asks for specific areas, for example `--section platform --section rook`.
   - Use `--format json` when follow-up processing is needed.
   - Use `--skip-prometheus` only when the user explicitly asks to avoid Prometheus or when the Prometheus API is unavailable.
3. If the script is unavailable or needs debugging, confirm access to the cluster:
   - `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig get nodes`
4. Inventory workload container resources from the Kubernetes API:
   - Prefer `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig get deploy,statefulset,daemonset,job,cronjob -A -o json`.
   - Extract each container's CPU and memory requests and limits.
   - Resolve CronJob resources from `.spec.jobTemplate.spec.template.spec`.
5. Query Prometheus for the last 24 hours:
   - Prefer the external `prometheus-api` ingress exposed by the monitoring module. It exists specifically for automation and API queries.
   - Read the endpoint and basic-auth credentials from `clusters/<cluster>/out/monitoring/terraform.tfstate` outputs:
     - `prometheus_api_url`
     - `prometheus_api_basic_auth_user`
     - `prometheus_api_basic_auth_password`
   - Never print the basic-auth password or full authenticated URL in the final answer.
   - If the ingress is unavailable, use the in-cluster Prometheus API when reachable.
   - If direct API access requires port-forwarding, use `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig -n monitoring port-forward svc/prometheus <local-port>:9090`.
   - If Grafana is the only available UI, use Grafana Explore to run the same PromQL queries.
6. Use these PromQL patterns for container usage:
   - CPU p95:
     `quantile_over_time(0.95, sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m]))[24h:5m])`
   - Memory max:
     `max_over_time(container_memory_working_set_bytes{container!="",image!=""}[24h])`
7. Join usage back to workloads:
   - Map pods to owners with `kube_pod_owner`.
   - Resolve ReplicaSets back to Deployments with `kube_replicaset_owner`.
   - For DaemonSets, StatefulSets, Jobs, and CronJobs, use the owning workload when available.
   - If Prometheus owner metrics are missing, fall back to Kubernetes pod owner references from `kubectl get pods -A -o json`.
8. Aggregate usage per workload container:
   - CPU: use the maximum p95 observed across matching pods in the last 24 hours.
   - Memory: use the maximum working set observed across matching pods in the last 24 hours.
   - For multi-replica workloads, compare per-container pod usage against per-container requests, not workload totals.
9. Flag findings:
   - Missing request if either CPU or memory request is absent.
   - Missing limit if either CPU or memory limit is absent.
   - CPU request below p95 if `CPU 24h p95 > CPU request`.
   - Memory request below max if `Memory 24h max > Memory request`.
   - `ok` only when requests and limits exist and 24h usage is within requests.
10. Add a short cluster summary before the table:
   - total CPU requested vs 24h CPU p95 or current CPU used, when available
   - total memory requested vs 24h memory max or current memory used, when available
   - count of containers with missing requests
   - count of containers with missing limits
11. Render the table using the required columns.
12. If repository files were changed, validate affected generated workspaces but do not run `tofu plan`, `tofu apply`, or a deployment script.
13. End every response after remediation or file changes with an apply command suggestion:
   - Run from `clusters/<cluster>`.
   - Use `../../scripts/deploy.sh --services-only` for service-only changes.
   - Add skip flags for unaffected stacks.
   - For Rook-only changes, use:
     `../../scripts/deploy.sh --services-only --skip-k8s-net --skip-identity --skip-platform --skip-monitoring`
   - For platform-only changes, use:
     `../../scripts/deploy.sh --services-only --skip-ceph --skip-k8s-net --skip-identity --skip-monitoring`

## Prometheus Notes

- `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes` usually come from kubelet/cAdvisor.
- Workload owner joins require kube-state-metrics metrics such as `kube_pod_owner` and `kube_replicaset_owner`.
- If kube-state-metrics is unavailable, state that owner attribution was resolved from Kubernetes API data.
- If Prometheus lacks 24 hours of data, use the longest available range and state the effective range.
- If a metric query returns duplicate series because of scrape labels, aggregate away non-identity labels before joining.

## Recommendation Rules

- For missing requests, recommend adding both CPU and memory requests before tuning limits.
- For memory requests below 24h max, recommend a request above observed max plus headroom.
- For CPU requests below p95, recommend a request near p95 plus modest headroom unless the workload is intentionally bursty.
- When setting CPU requests or limits, write integer CPU values in Kubernetes-canonical core form to avoid OpenTofu/Kubernetes provider normalization errors:
  - use `"1"` instead of `"1000m"`
  - use `"2"` instead of `"2000m"`
  - keep non-integer CPU values as millicores, such as `200m`, `500m`, or `1500m` for 1.5 cores
  - `scripts/deploy.sh` rejects integer CPU millicore values in modules that are included in the selected deployment path
- For missing memory limits, recommend setting them for application workloads where OOM behavior is acceptable and understood.
- For missing CPU limits, do not automatically recommend strict CPU limits for latency-sensitive workloads; recommend review instead.
- If a namespace is system-owned, prefer conservative recommendations and call out that changes should follow the component's supported configuration path.

## How To Invoke

Typical user requests that should trigger this workflow:

- `Audit CPU and RAM requests for cluster eht`
- `Find services without Kubernetes resource requests or limits`
- `Compare Kubernetes requests with the last 24h Prometheus usage`
- `Why are Rancher reserved CPU and memory lower than real usage?`
- `Follow docs/agent-workflows/cluster-resource-requests.md for <cluster>`
