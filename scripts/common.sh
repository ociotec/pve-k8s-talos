#!/usr/bin/env bash
set -euo pipefail

repo_root=""
clusters_dir=""
cluster_name=""
cluster_dir=""
cluster_out_dir=""
cluster_root_workspace=""
cluster_root_patches_dir=""
cluster_k8s_net_workspace=""
cluster_monitoring_workspace=""
cluster_rook_01_workspace=""
cluster_rook_02_workspace=""
cluster_rook_03_workspace=""
cluster_rook_04_workspace=""
cluster_envrc_path=""
cluster_constants_path=""
cluster_vms_path=""
cluster_resources_path=""
cluster_k8s_net_constants_path=""
cluster_ceph_constants_path=""
cluster_monitoring_constants_path=""
cluster_certs_dir=""
cluster_talosconfig_path=""
cluster_kubeconfig_path=""

message() {
  echo -e "\033[34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

error() {
  echo -e "\033[31m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    error "Missing required command: ${cmd}"
    exit 1
  fi
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

setup_cluster_context() {
  local script_path="$1"
  local script_base
  local requested_cluster="$2"
  local current_dir
  local current_parent
  local current_cluster

  if [[ -d "${script_path}" ]]; then
    script_base="${script_path}"
  else
    script_base="$(dirname "${script_path}")"
  fi

  repo_root="$(cd "${script_base}/.." && pwd -P)"
  clusters_dir="${repo_root}/clusters"
  current_dir="$(pwd -P)"
  current_parent="$(basename "$(dirname "${current_dir}")")"
  current_cluster="$(basename "${current_dir}")"

  if [[ "${current_parent}" != "clusters" ]]; then
    error "Run this script from clusters/<cluster>."
    exit 1
  fi

  if [[ "${current_cluster}" == "sample" ]]; then
    error "clusters/sample is only for examples; run from a real cluster directory."
    exit 1
  fi

  if [[ -z "${requested_cluster}" ]]; then
    requested_cluster="${current_cluster}"
  fi

  if [[ "${current_cluster}" != "${requested_cluster}" ]]; then
    error "Current directory cluster (${current_cluster}) does not match --cluster ${requested_cluster}."
    exit 1
  fi

  cluster_name="${requested_cluster}"
  cluster_dir="${clusters_dir}/${cluster_name}"
  if [[ "${current_dir}" != "${cluster_dir}" ]]; then
    error "Expected to run from ${cluster_dir}, but current directory is ${current_dir}."
    exit 1
  fi

  cluster_out_dir="${cluster_dir}/out"
  cluster_root_workspace="${cluster_out_dir}/root"
  cluster_root_patches_dir="${cluster_root_workspace}/patches"
  cluster_k8s_net_workspace="${cluster_out_dir}/k8s-net"
  cluster_monitoring_workspace="${cluster_out_dir}/monitoring"
  cluster_rook_01_workspace="${cluster_out_dir}/rook/01-crds-common-operator"
  cluster_rook_02_workspace="${cluster_out_dir}/rook/02-cluster"
  cluster_rook_03_workspace="${cluster_out_dir}/rook/03-dashboard"
  cluster_rook_04_workspace="${cluster_out_dir}/rook/04-csi"
  cluster_envrc_path="${cluster_dir}/.envrc"
  cluster_constants_path="${cluster_dir}/constants.auto.tfvars"
  cluster_vms_path="${cluster_dir}/vms.auto.tfvars"
  cluster_resources_path="${cluster_dir}/resources.auto.tfvars"
  cluster_k8s_net_constants_path="${cluster_dir}/k8s_net_constants.tf"
  cluster_ceph_constants_path="${cluster_dir}/ceph_constants.tf"
  cluster_monitoring_constants_path="${cluster_dir}/monitoring_constants.tf"
  cluster_certs_dir="${cluster_dir}/certs"
  cluster_talosconfig_path="${cluster_out_dir}/talosconfig"
  cluster_kubeconfig_path="${cluster_out_dir}/kubeconfig"
}

require_cluster_file() {
  local path="$1"
  local description="$2"

  if [[ ! -r "${path}" ]]; then
    error "Cannot read ${description}: ${path}"
    exit 1
  fi
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
}

link_into_workspace() {
  local source="$1"
  local target="$2"

  ensure_parent_dir "${target}"
  rm -rf "${target}"
  ln -sfn "${source}" "${target}"
}

reset_workspace_file() {
  local path="$1"
  rm -f "${path}"
}
