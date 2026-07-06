# Targeted Benchmark Scaling Workflow

Use this workflow when the user asks to run, stop, or size benchmark workloads
for a real cluster by CPU or memory utilization target.

## Rules

- Treat `scripts/scale-benchmarks-to-target.sh` as the default operational path
  for CPU and memory benchmark scaling.
- Run the script from `clusters/<cluster>`, preferably through `direnv exec .`.
- Start with a dry-run unless the user explicitly asks to apply or execute the
  benchmark scaling in the same request.
- If applying, use the exact same target values from the dry-run and add
  `--apply`. Do not expand the scope to disk or Kafka benchmarks unless the user
  explicitly asks for those workloads.
- Use `--stop --apply` only when the user explicitly asks to stop benchmark load.
- Do not run `scripts/deploy.sh` for benchmark scaling. Deployment is only needed
  if the benchmark namespace or workloads do not exist.

## Commands

Dry-run CPU and memory targets:

```bash
direnv exec . ../../scripts/scale-benchmarks-to-target.sh --cluster <cluster> --cpu <percent> --memory <percent>
```

Apply the same targets:

```bash
direnv exec . ../../scripts/scale-benchmarks-to-target.sh --cluster <cluster> --cpu <percent> --memory <percent> --apply
```

Stop CPU and memory benchmark load:

```bash
direnv exec . ../../scripts/scale-benchmarks-to-target.sh --cluster <cluster> --stop --apply
```

## Interpretation

- Capacity is based on Ready schedulable node allocatable CPU and memory.
- Nodes with `NoSchedule` or `NoExecute` taints are excluded unless
  `--include-tainted-nodes` is passed.
- Current usage comes from the Kubernetes `metrics.k8s.io` pod metrics API.
- Existing CPU and memory benchmark pod usage is subtracted before calculating
  desired replicas, so repeated runs compute absolute desired replica counts
  rather than blindly adding more replicas.
- Desired replicas are capped against per-node Kubernetes request headroom. This
  prevents the script from asking for pods that the scheduler cannot place even
  when live usage appears below the requested target.
- CPU replicas are based on the CPU benchmark container CPU limit/request.
- Memory replicas are based on the `stress-ng --vm-bytes` value, not the pod
  memory limit.
- If the schedulability cap is lower than the live-usage target, report the cap
  clearly; the requested percentage cannot be reached with the current benchmark
  pod shapes and existing cluster reservations.
- The result is an immediate sizing estimate. After applying, wait for pods to
  become Ready and metrics to refresh, then rerun a dry-run if the target needs
  tighter convergence.

## Missing Workloads

If the benchmark namespace or deployments are missing, tell the user deployment
is needed and provide the benchmark-only deployment command from the cluster
directory:

```bash
../../scripts/deploy.sh --services-only --skip-ceph --skip-k8s-net --skip-identity --skip-s3-storage --skip-platform --skip-kafka --skip-monitoring
```
