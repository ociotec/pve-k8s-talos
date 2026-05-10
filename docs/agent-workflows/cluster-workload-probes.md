# Cluster Workload Probes Workflow

Use this workflow when the user wants to audit Kubernetes workload compliance with readiness, liveness, and startup probe rules for a repository cluster.

This workflow is repo-local guidance for agents. It is not a globally installed Codex skill.

## Required Input

The cluster name is required because kubeconfigs and generated workspaces are cluster-specific.

If the user does not provide a cluster name, ask for it before running commands.

## Scope

Audit running Kubernetes workload containers for missing health probes.

Include:

- Deployments, StatefulSets, and DaemonSets.
- All namespaces unless the user requests a narrower scope.
- Regular workload containers.

Exclude by default:

- Jobs and CronJobs, because readiness/liveness probes are usually not meaningful for finite execution.
- Init containers, because Kubernetes does not run readiness/liveness/startup probes on init containers.
- Ephemeral debug containers.
- Static mirror pods when no owning workload can be resolved.

## Required Behavior

- Use the user's language unless they ask for another language.
- Present the result as a Markdown table.
- Prefer invoking `scripts/audit-cluster-probes.sh` instead of manually chaining `kubectl` and `jq`.
- Unless the user asks for a narrower report, run the complete audit and include OK containers:
  `../../scripts/audit-cluster-probes.sh --cluster <cluster> --include-ok --all`
- Always show workloads missing readiness or liveness probes first.
- Treat readiness and liveness probes as required for long-running service workloads.
- Treat startup probes as recommended when startup may be slow because of WAL replay, migrations, storage recovery, cache warmup, JVM warmup, or similar initialization work.
- Do not change manifests unless the user explicitly asks for remediation.
- Never apply changes to the cluster from this workflow.
- Never run `tofu plan`, `tofu apply`, or any deployment script from this workflow.
- Only inspect, edit repository files when requested, and run validation commands such as `tofu init` and `tofu validate`.
- After any remediation analysis or file changes, always end the response by showing the minimal `scripts/deploy.sh` command needed to apply the changes, using skip flags for unaffected stacks. The user runs it manually.
- Do not include secrets, private hostnames, private IPs, or raw private URLs in the final answer.

## Output Format

Use this column set unless the user requests a different shape:

| Section | Namespace | Workload | Container | Readiness | Liveness | Startup | Finding | Recommendation |

Column rules:

- `Section`: repository/deployment area affected, such as `identity`, `k8s-net`, `monitoring`, `platform`, `rook`, or `other`.
- `Namespace`: Kubernetes namespace.
- `Workload`: `<kind>/<name>`, for example `Deployment/prometheus`.
- `Container`: regular container name.
- `Readiness`: `present:<type>` or `missing`, where type is `httpGet`, `tcpSocket`, `exec`, `grpc`, or `unknown`.
- `Liveness`: `present:<type>` or `missing`.
- `Startup`: `present:<type>` or `missing`.
- `Finding`: concise issue such as `missing readiness`, `missing liveness`, `missing readiness and liveness`, or `ok`.
- `Recommendation`: concise next action, such as `add readinessProbe`, `add livenessProbe`, `add readinessProbe and livenessProbe`, `consider startupProbe for slow startup`, or `no change`.

Sort rows by severity:

1. Missing readiness and liveness.
2. Missing readiness.
3. Missing liveness.
4. OK rows without startup probes.
5. OK rows with all probes.

Within each severity group, sort by:

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
   - Default: `../../scripts/audit-cluster-probes.sh --cluster <cluster> --include-ok --all`
   - Use `--top <n>` only when the user asks for a truncated report.
   - Use one or more `--section <name>` flags when the user asks for specific areas, for example `--section monitoring --section platform`.
   - Use `--format json` when follow-up processing is needed.
   - Use `--include-jobs` only when the user explicitly asks to inspect Jobs and CronJobs.
3. If the script is unavailable or needs debugging, confirm access to the cluster:
   - `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig get nodes`
4. Inventory workload containers from the Kubernetes API:
   - Prefer `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig get deploy,statefulset,daemonset -A -o json`.
   - Include `job,cronjob` only for explicit job audits.
   - Extract each regular container's `readinessProbe`, `livenessProbe`, and `startupProbe`.
   - Resolve CronJob probe data from `.spec.jobTemplate.spec.template.spec`.
5. Flag findings:
   - Missing readiness if `readinessProbe` is absent.
   - Missing liveness if `livenessProbe` is absent.
   - Missing startup is informational unless the workload is known to start slowly.
   - `ok` only when readiness and liveness probes exist.
6. Add a short cluster summary before the table:
   - total audited containers
   - count missing readiness probes
   - count missing liveness probes
   - count missing startup probes
   - count fully compliant with readiness and liveness
7. Render the table using the required columns.
8. If repository files were changed, validate affected generated workspaces but do not run `tofu plan`, `tofu apply`, or a deployment script.
9. End every response after remediation or file changes with an apply command suggestion:
   - Run from `clusters/<cluster>`.
   - Use `../../scripts/deploy.sh --services-only` for service-only changes.
   - Add skip flags for unaffected stacks.
   - For monitoring-only changes, use:
     `../../scripts/deploy.sh --services-only --skip-ceph --skip-k8s-net --skip-identity --skip-platform`

## Probe Rules

- Prefer HTTP probes for HTTP services that expose explicit health endpoints.
- Use readiness endpoints that prove the process can serve real traffic or API calls.
- Use liveness endpoints that prove the process is not deadlocked or permanently unhealthy.
- Use startup probes for components with known slow initialization so liveness checks do not kill healthy startup work.
- Avoid overly aggressive liveness thresholds for storage-backed services; slow I/O should not cause repeated restarts.
- For Prometheus, prefer:
  - readiness/startup: `/-/ready`
  - liveness: `/-/healthy`

## How To Invoke

Typical user requests that should trigger this workflow:

- `Audit probes for cluster eht`
- `Find services without readiness or liveness probes`
- `Check Kubernetes health-check compliance`
- `Which monitoring workloads are missing startup probes?`
- `Follow docs/agent-workflows/cluster-workload-probes.md for <cluster>`
