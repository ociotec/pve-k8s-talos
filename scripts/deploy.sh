#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: deploy.sh [options]

Deploys the Talos + Rook Ceph stack. By default it skips the destructive
destroy step and only applies.

Options:
  -d, --destroy       Destroy the cluster first (dangerous).
  -c, --skip-ceph     Skip all Rook Ceph steps (operator, cluster, dashboard, CSI).
  -n, --skip-k8s-net  Skip k8s networking and ingress (k8s-net) steps (ingress, MetalLB, cert-manager, Portainer).
  -m, --skip-monitoring  Skip monitoring stack (Prometheus, Loki, Grafana).
  -h, --help          Show this help message.
USAGE
}

destroy_first=false
skip_ceph=false
skip_k8s_net=false
skip_monitoring=false

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
    -n|--skip-k8s-net)
      skip_k8s_net=true
      shift
      ;;
    -m|--skip-monitoring)
      skip_monitoring=true
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

purge_state_dir() {
  local state_dir="$1"
  if [[ -d "${state_dir}" ]]; then
    rm -f "${state_dir}/terraform.tfstate" "${state_dir}/terraform.tfstate.backup"
  fi
}

URL_FMT_START="\033[1m\033[3m\033[4m"
URL_FMT_END="\033[24m\033[23m\033[22m"
DATA_FMT_START="\033[1m\033[3m"
DATA_FMT_END="\033[23m\033[22m"

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

disk_by_id_prefix() {
  awk -F'"' '/"disk_by_id_prefix"/ { print $4; exit }' "$1"
}

validate_disk_by_id_prefix() {
  local worker_ip="$1"
  local prefix="$2"
  local timeout_seconds="${3:-120}"
  local start
  local output

  if [[ -z "${prefix}" ]]; then
    error "Missing vm.disk_by_id_prefix in vms_constants.tf." >&2
    exit 1
  fi

  if ! command -v talosctl >/dev/null 2>&1; then
    error "talosctl is required to validate vm.disk_by_id_prefix." >&2
    exit 1
  fi

  start="$(date +%s)"
  while true; do
    if output="$(talosctl -n "${worker_ip}" ls /dev/disk/by-id 2>/dev/null)"; then
      if printf '%s\n' "${output}" | grep -q "${prefix}[0-9]\\+"; then
        return 0
      fi
      error "vm.disk_by_id_prefix (${prefix}) not found on ${worker_ip}." >&2
      error "Fix: run 'talosctl -n ${worker_ip} ls /dev/disk/by-id' and look for ${prefix}0." >&2
      exit 1
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      error "Timed out waiting to validate vm.disk_by_id_prefix on ${worker_ip}." >&2
      error "Fix: ensure Talos is up, then verify /dev/disk/by-id contains ${prefix}0." >&2
      exit 1
    fi
    sleep 5
  done
}

deploy_start="$(start_timer)"

tofu init -upgrade 1>/dev/null
if [[ "${destroy_first}" == "true" ]]; then
  message "Destroying Talos cluster VMs..."
  tofu destroy -auto-approve -refresh=false 1>/dev/null
  message "Done."
  message "Purging local OpenTofu state files..."
  purge_state_dir "${PWD}"
  purge_state_dir "${PWD}/k8s-net"
  purge_state_dir "${PWD}/rook/01-crds-common-operator"
  purge_state_dir "${PWD}/rook/02-cluster"
  purge_state_dir "${PWD}/rook/03-dashboard"
  purge_state_dir "${PWD}/rook/04-csi"
  purge_state_dir "${PWD}/monitoring"
fi

message "Deploying the Talos cluster (PVE VMs creation, Talos cluster initialization, k8s bootstrapping)..."
./scripts/gen-talos-assets.sh
tofu apply -auto-approve 1>/dev/null
mkdir -p ~/.talos ~/.kube
if ! tofu output -raw talosconfig > ~/.talos/config 2>/dev/null; then
  if [[ -f talosconfig ]]; then
    cp talosconfig ~/.talos/config
  else
    error "Failed to write talosconfig from tofu outputs." >&2
    exit 1
  fi
fi
if ! tofu output -raw kubeconfig > ~/.kube/config 2>/dev/null; then
  if [[ -f kubeconfig ]]; then
    cp kubeconfig ~/.kube/config
  else
    error "Failed to write kubeconfig from tofu outputs." >&2
    exit 1
  fi
fi
worker_ip=$(first_worker_ip "${PWD}/vms_list.tf")
if [[ -z "${worker_ip}" ]]; then
  error "Failed to determine the first worker name/IP from vms_list.tf." >&2
  exit 1
fi
prefix_value=$(disk_by_id_prefix "${PWD}/vms_constants.tf")
validate_disk_by_id_prefix "${worker_ip}" "${prefix_value}"
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
  message "Rook Ceph Dashboard is available at ${URL_FMT_START}https://${worker_ip}:${dashboard_nodeport}/${URL_FMT_END}"
  dashboard_password=""
  for _ in {1..12}; do
    if kubectl -n rook-ceph get secret rook-ceph-dashboard-password 1>/dev/null 2>&1; then
      dashboard_password=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 --decode)
      break
    fi
    sleep 5
  done
  if [[ -n "${dashboard_password}" ]]; then
    message "Login with username '${DATA_FMT_START}admin${DATA_FMT_END}' and the following password: ${DATA_FMT_START}${dashboard_password}${DATA_FMT_END}"
  else
    error "Dashboard password secret not found yet. Retry: kubectl -n rook-ceph get secret rook-ceph-dashboard-password"
    exit 1
  fi
fi

if [[ "${skip_k8s_net}" == "true" ]]; then
  message "Skipping k8s networking and ingress (k8s-net) steps."
else
  message "Deploying k8s networking and ingress (k8s-net)..."
  tofu -chdir=k8s-net init 1>/dev/null
  tofu -chdir=k8s-net apply -auto-approve \
    -target=kubernetes_manifest.cert_manager_crds \
    -target=kubernetes_manifest.metallb_native_crds 1>/dev/null
  tofu -chdir=k8s-net apply -auto-approve 1>/dev/null
  portainer_url="$(tofu -chdir=k8s-net output -raw portainer_url)"
  rook_dashboard_url="$(tofu -chdir=k8s-net output -raw rook_ceph_dashboard_url)"
  message "Portainer URL: ${URL_FMT_START}${portainer_url}${URL_FMT_END}"
  message "Rook Ceph dashboard URL: ${URL_FMT_START}${rook_dashboard_url}${URL_FMT_END}"
fi

if [[ "${skip_k8s_net}" == "true" || "${skip_monitoring}" == "true" ]]; then
  message "Skipping monitoring stack."
else
  message "Deploying monitoring stack..."
  tofu -chdir=monitoring init 1>/dev/null
  tofu -chdir=monitoring apply -auto-approve 1>/dev/null
  message "Restarting Grafana to reload provisioned dashboards..."
  kubectl -n monitoring rollout restart deploy/grafana 1>/dev/null
  grafana_url="$(tofu -chdir=monitoring output -raw grafana_url)"
  prometheus_url="$(tofu -chdir=monitoring output -raw prometheus_url)"
  grafana_user="$(tofu -chdir=monitoring output -raw grafana_admin_user)"
  grafana_password="$(tofu -chdir=monitoring output -raw grafana_admin_password)"
  message "Grafana URL: ${URL_FMT_START}${grafana_url}${URL_FMT_END}"
  message "Prometheus URL: ${URL_FMT_START}${prometheus_url}${URL_FMT_END}"
  message "Grafana admin user: ${DATA_FMT_START}${grafana_user}${DATA_FMT_END}"
  message "Grafana admin password: ${DATA_FMT_START}${grafana_password}${DATA_FMT_END}"
fi

message "Cluster deployed successfully in $(render_elapsed "${deploy_start}")."
