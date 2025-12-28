#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: deploy.sh [options]

Deploys the Talos + Rook Ceph stack. By default it skips the destructive
destroy step and only applies.

Options:
  -d, --destroy   Destroy the cluster first (dangerous).
  -c, --skip-ceph Skip all Rook Ceph steps (operator, cluster, dashboard, CSI).
  -h, --help      Show this help message.
USAGE
}

destroy_first=false
skip_ceph=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--destroy)
      destroy_first=true
      shift
      ;;
    -c|--skip-ceph)
      skip_ceph=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

function message() {
  echo -e "\033[34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

function error() {
  echo -e "\033[31m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

start_timer() {
  date +%s
}

render_elapsed() {
  local start="$1"
  local end
  local elapsed
  local hours
  local minutes
  local seconds
  local output

  end="$(date +%s)"
  elapsed=$((end - start))
  hours=$((elapsed / 3600))
  minutes=$(((elapsed % 3600) / 60))
  seconds=$((elapsed % 60))

  if (( hours > 0 )); then
    output="$(printf "%dh %d' %02d''" "${hours}" "${minutes}" "${seconds}")"
  elif (( minutes > 0 )); then
    output="$(printf "%d' %02d''" "${minutes}" "${seconds}")"
  else
    output="$(printf "%d''" "${seconds}")"
  fi
  printf "%s" "${output}"
}

wait_for_pods_ready() {
  local namespace="$1"
  local selector_input="${2:-}"
  local timeout="${3:-300s}"
  local pods
  local current
  local selector_arg=()

  if [[ -n "${selector_input}" ]]; then
    selector_arg=(-l "app in (${selector_input})")
  fi

  while true; do
    if ! kubectl get namespace "${namespace}" 1>/dev/null 2>&1; then
      sleep 5
      continue
    fi

    pods="$(kubectl -n "${namespace}" get pods "${selector_arg[@]}" --no-headers 2>/dev/null \
      | awk '$3!="Completed" && $3!="Terminating"{print $1}' \
      | sort)"
    if [[ -z "${pods}" ]]; then
      sleep 5
      continue
    fi

    for pod in ${pods}; do
      kubectl -n "${namespace}" wait --for=condition=Ready "pod/${pod}" --timeout="${timeout}" || true
    done

    sleep 5
    current="$(kubectl -n "${namespace}" get pods "${selector_arg[@]}" --no-headers 2>/dev/null \
      | awk '$3!="Completed" && $3!="Terminating"{print $1}' \
      | sort)"
    if [[ "${current}" == "${pods}" ]]; then
      echo "All matching pods are ready and stable in ${namespace}."
      break
    fi
  done
}

wait_for_cephcluster_ready() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3:-900}"
  local start
  local phase
  local health

  start="$(date +%s)"
  while true; do
    echo -n "."
    phase="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    health="$(kubectl -n "${namespace}" get cephcluster "${name}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
    if [[ "${phase}" == "Ready" && "${health}" == "HEALTH_OK" ]]; then
      echo
      message "CephCluster ${namespace}/${name} is Ready (phase=Ready, health=HEALTH_OK)."
      break
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      echo
      error "Timed out waiting for CephCluster ${namespace}/${name} to become Ready (phase=${phase:-unknown}, health=${health:-unknown})." >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_dashboard_cert() {
  local timeout_seconds="${1:-300}"
  local start

  start="$(date +%s)"
  while true; do
    if kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph config-key get mgr/dashboard/crt 1>/dev/null 2>&1 \
      && kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph config-key get mgr/dashboard/key 1>/dev/null 2>&1; then
      message "Ceph dashboard SSL certificate is available."
      break
    fi
    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting for Ceph dashboard SSL certificate to be available." >&2
      exit 1
    fi
    sleep 5
  done
}

first_worker_ip() {
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) { in_block=1; is_worker=0; next }
    in_block && match($0, /type[[:space:]]*=[[:space:]]*"worker"/) { is_worker=1 }
    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      if (is_worker) {
        ip = $0
        sub(/^[^"]*"/, "", ip)
        sub(/".*/, "", ip)
        print ip
        exit
      }
      in_block=0
      is_worker=0
    }
    in_block && /}/ { in_block=0; is_worker=0 }
  ' "$1"
}

deploy_start="$(start_timer)"

tofu init -upgrade 1>/dev/null
if [[ "${destroy_first}" == "true" ]]; then
  message "Destroying Talos cluster VMs..."
  tofu destroy -auto-approve -refresh=false 1>/dev/null
  message "Done."
fi

message "Deploying the Talos cluster (PVE VMs creation, Talos cluster initialization, k8s bootstrapping)..."
./scripts/gen-talos-assets.sh
tofu apply -auto-approve 1>/dev/null
cp talosconfig ~/.talos/config
cp kubeconfig ~/.kube/config
message "k8s cluster is up and running. Current nodes:"
kubectl get nodes

if [[ "${skip_ceph}" == "true" ]]; then
  message "Skipping Rook Ceph steps."
else
  ceph_phase="$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${ceph_phase}" == "Ready" ]]; then
    message "Rook Ceph cluster already Ready; skipping operator/cluster apply."
  else
    message "Deploying Rook Ceph operator..."
    tofu -chdir=rook/01-crds-common-operator init 1>/dev/null
    tofu -chdir=rook/01-crds-common-operator apply -auto-approve 1>/dev/null
    wait_for_pods_ready "rook-ceph" "rook-ceph-operator" "180s"

    message "Deploying Rook Ceph cluster..."
    tofu -chdir=rook/02-cluster init 1>/dev/null
    tofu -chdir=rook/02-cluster apply -auto-approve 1>/dev/null
    wait_for_cephcluster_ready "rook-ceph" "rook-ceph" "900"
  fi

  message "Deploying Rook Ceph CSI storage classes..."
  tofu -chdir=rook/04-csi init 1>/dev/null
  tofu -chdir=rook/04-csi apply -auto-approve 1>/dev/null
  kubectl -n rook-ceph get storageclasses.storage.k8s.io

  message "Deploying Rook Ceph dashboard..."
  tofu -chdir=rook/03-dashboard init 1>/dev/null
  tofu -chdir=rook/03-dashboard apply -auto-approve 1>/dev/null
  wait_for_dashboard_cert "300"
  dashboard_nodeport=$(kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard-external-https -o jsonpath='{.spec.ports[?(@.name=="dashboard")].nodePort}')
  worker_ip=$(first_worker_ip "${PWD}/vms_list.tf")
  message "Rook Ceph Dashboard is available at https://${worker_ip}:${dashboard_nodeport}/"
  dashboard_password=""
  for _ in {1..12}; do
    if kubectl -n rook-ceph get secret rook-ceph-dashboard-password 1>/dev/null 2>&1; then
      dashboard_password=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 --decode)
      break
    fi
    sleep 5
  done
  if [[ -n "${dashboard_password}" ]]; then
    message "Login with username 'admin' and the following password: ${dashboard_password}"
  else
    error "Dashboard password secret not found yet. Retry: kubectl -n rook-ceph get secret rook-ceph-dashboard-password"
    exit 1
  fi
fi

message "Cluster deployed successfully in $(render_elapsed "${deploy_start}")."
