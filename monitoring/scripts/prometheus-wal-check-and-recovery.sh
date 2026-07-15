#!/bin/sh
set -eu

namespace=monitoring
deployment=prometheus
cleanup_pod=prometheus-wal-check-and-recovery-cleanup
cleanup_script=/scripts/prometheus-wal-cleanup.sh
log_window="${PROMETHEUS_WAL_RECOVERY_LOG_WINDOW:-96h}"
prometheus_image="${PROMETHEUS_IMAGE:?PROMETHEUS_IMAGE is required}"
cpu_request="${RECOVERY_CPU_REQUEST:?RECOVERY_CPU_REQUEST is required}"
cpu_limit="${RECOVERY_CPU_LIMIT:?RECOVERY_CPU_LIMIT is required}"
mem_request="${RECOVERY_MEM_REQUEST:?RECOVERY_MEM_REQUEST is required}"
mem_limit="${RECOVERY_MEM_LIMIT:?RECOVERY_MEM_LIMIT is required}"

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

get_metric_value() {
  metric_name="$1"
  kubectl -n "$namespace" exec deploy/"$deployment" -- \
    wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
    | awk -v metric="$metric_name" '$1 == metric { print $2; exit }' || true
}

log "Inspecting Prometheus WAL health using logs from the last $log_window."
prometheus_logs="$(kubectl -n "$namespace" logs deploy/"$deployment" --since="$log_window" 2>&1 || true)"
bad_segment="$(
  printf '%s\n' "$prometheus_logs" \
    | sed -n 's/.*corruption in segment \/prometheus\/wal\/\([0-9][0-9]*\).*/\1/p' \
    | tail -n 1
)"

wal_truncation_failures="$(get_metric_value prometheus_tsdb_wal_truncations_failed_total)"
compaction_failures="$(get_metric_value prometheus_tsdb_compactions_failed_total)"
wal_corruptions="$(get_metric_value prometheus_tsdb_wal_corruptions_total)"
log "Current metrics: prometheus_tsdb_wal_truncations_failed_total=${wal_truncation_failures:-unavailable}, prometheus_tsdb_compactions_failed_total=${compaction_failures:-unavailable}, prometheus_tsdb_wal_corruptions_total=${wal_corruptions:-unavailable}."

if [ -z "$bad_segment" ]; then
  if printf '%s\n%s\n%s\n' "$wal_truncation_failures" "$compaction_failures" "$wal_corruptions" | awk '($1 + 0) > 0 { found = 1 } END { exit found ? 0 : 1 }'; then
    log "Prometheus reports TSDB/WAL failures, but no corrupt WAL segment was found in recent logs. Refusing partial recovery without a segment boundary."
    exit 2
  fi
  log "No WAL corruption evidence found. Nothing to recover."
  exit 0
fi

log "Detected corrupt WAL segment: $bad_segment. Recovery will delete this segment and later WAL/checkpoint entries only."
original_replicas="$(kubectl -n "$namespace" get deploy "$deployment" -o jsonpath='{.spec.replicas}')"
if [ -z "$original_replicas" ]; then
  original_replicas=1
fi
log "Original deployment replicas: $original_replicas."

log "Scaling deployment/$deployment to 0."
kubectl -n "$namespace" scale deploy/"$deployment" --replicas=0

log "Waiting for Prometheus pods to terminate."
if ! kubectl -n "$namespace" wait --for=delete pod -l app=prometheus --timeout=300s; then
  log "Prometheus pods did not terminate within timeout. Current pods:"
  kubectl -n "$namespace" get pods -l app=prometheus -o wide || true
  exit 1
fi

log "Deleting any stale cleanup pod."
kubectl -n "$namespace" delete pod "$cleanup_pod" --ignore-not-found --wait=true

log "Creating cleanup pod for segment $bad_segment."
cat <<EOF | kubectl -n "$namespace" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $cleanup_pod
  namespace: $namespace
  labels:
    app: prometheus-wal-check-and-recovery-cleanup
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: prometheus
    app.kubernetes.io/component: recovery
    app.kubernetes.io/part-of: prometheus
    app.kubernetes.io/managed-by: infrastructure
    pve-k8s-talos/section: monitoring
spec:
  priorityClassName: infra-observability
  restartPolicy: Never
  securityContext:
    fsGroup: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: cleanup
      image: $prometheus_image
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: $cpu_request
          memory: $mem_request
        limits:
          cpu: $cpu_limit
          memory: $mem_limit
      env:
        - name: BAD_SEGMENT
          value: "$bad_segment"
      command:
        - sh
        - /scripts/prometheus-wal-cleanup.sh
      volumeMounts:
        - name: data
          mountPath: /prometheus
        - name: recovery-scripts
          mountPath: /scripts
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: prometheus-data
    - name: recovery-scripts
      configMap:
        name: prometheus-wal-check-and-recovery-scripts
        defaultMode: 365
EOF

log "Waiting for cleanup pod to complete."
cleanup_status=0
if ! kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$cleanup_pod" --timeout=300s; then
  cleanup_status=1
fi
log "Cleanup pod logs follow."
kubectl -n "$namespace" logs pod/"$cleanup_pod" || true
kubectl -n "$namespace" delete pod "$cleanup_pod" --ignore-not-found --wait=true
if [ "$cleanup_status" -ne 0 ]; then
  log "Cleanup pod failed. Prometheus remains scaled to 0 for manual inspection."
  exit 1
fi

log "Scaling deployment/$deployment to 1."
kubectl -n "$namespace" scale deploy/"$deployment" --replicas=1
log "Waiting for Prometheus rollout."
if ! kubectl -n "$namespace" rollout status deploy/"$deployment" --timeout=600s; then
  log "Prometheus rollout failed or timed out. Recent logs:"
  kubectl -n "$namespace" logs deploy/"$deployment" --since=10m || true
  exit 1
fi

log "Prometheus rollout succeeded. Recent startup logs:"
kubectl -n "$namespace" logs deploy/"$deployment" --since=10m || true
log "WAL health repair job completed successfully."
