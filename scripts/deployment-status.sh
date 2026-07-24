#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

status_namespace="kube-system"
status_configmap="pve-k8s-talos-deployment-status"
schema_version="1"
kubectl_bin="${DEPLOYMENT_STATUS_KUBECTL_BIN:-kubectl}"

usage() {
  cat <<'USAGE'
Usage:
  deployment-status.sh show
  deployment-status.sh baseline --sections <section,...> --confirm-aligned
      [--platform-commit <commit> --cluster-commit <commit>] [--dry-run]
  deployment-status.sh record --section <section> --deployment-id <id>
      [--platform-commit <commit> --cluster-commit <commit>
       --platform-dirty <true|false> --cluster-dirty <true|false>] [--dry-run]

  deployment-status.sh record-runtime-state --deployment-id <id>
      --cluster-commit <commit> [--dry-run]

Reads or updates the deployment provenance stored in Kubernetes. Run this
script from clusters/<cluster> with the cluster-local environment loaded.

Canonical sections:
  k8s, k8s-net, ceph, identity, s3, monitoring, platform, kafka, benchmark

Commands:
  show
      Print the current deployment status as structured JSON.

  baseline
      Create an operator-confirmed baseline without claiming that a deployment
      was observed. Both repositories must be clean unless explicit commits are
      supplied for both with --platform-commit and --cluster-commit.

  record
      Record one section after a successful scripts/deploy.sh section.

  record-runtime-state
      Record the cluster repository commit containing the resulting runtime
      state after a successful deployment.
USAGE
}

is_valid_section() {
  case "$1" in
    k8s|k8s-net|ceph|identity|s3|monitoring|platform|kafka|benchmark)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

repository_root() {
  local path="$1"
  local top_level

  top_level="$(git -C "${path}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${top_level}" ]]; then
    return 1
  fi
  (
    cd "${top_level}"
    pwd -P
  )
}

require_independent_cluster_repository() {
  local actual_root
  local expected_root

  actual_root="$(repository_root "${cluster_dir}" || true)"
  expected_root="$(cd "${cluster_dir}" && pwd -P)"
  if [[ -z "${actual_root}" || "${actual_root}" != "${expected_root}" ]]; then
    error "Cluster ${cluster_name} must be an independent Git repository to record deployment provenance." >&2
    exit 1
  fi
}

sanitize_repository_url() {
  local url="$1"

  # Strip URL userinfo and query/fragment data so tokens cannot be persisted.
  url="$(printf '%s' "${url}" | sed -E \
    -e 's#^([[:alpha:]][[:alnum:]+.-]*://)[^/@]+@#\1#' \
    -e 's#[?#].*$##')"

  # Normalize common SCP-style Git URLs while dropping the SSH username.
  if [[ "${url}" =~ ^[^/@]+@([^:]+):(.+)$ ]]; then
    url="ssh://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  printf '%s' "${url}"
}

repository_url() {
  local path="$1"
  local role="$2"
  local url

  url="$(git -C "${path}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    error "Repository ${role} does not have an origin URL." >&2
    exit 1
  fi
  sanitize_repository_url "${url}"
}

repository_is_dirty() {
  local path="$1"
  [[ -n "$(git -C "${path}" status --porcelain=v1 --untracked-files=normal)" ]]
}

resolve_explicit_commit() {
  local path="$1"
  local role="$2"
  local requested_commit="$3"
  local resolved_commit

  if ! git -C "${path}" cat-file -e "${requested_commit}^{commit}" 2>/dev/null; then
    error "Commit ${requested_commit} is not available in repository ${role}." >&2
    exit 1
  fi
  resolved_commit="$(git -C "${path}" rev-parse "${requested_commit}^{commit}")"
  printf '%s' "${resolved_commit}"
}

current_commit() {
  local path="$1"
  git -C "${path}" rev-parse HEAD
}

build_status_manifest() {
  local sections_json="$1"
  local section_data="$2"
  local platform_url="$3"
  local cluster_url="$4"
  local repositories_json

  repositories_json="$(
    jq -cn \
      --arg platform_url "${platform_url}" \
      --arg cluster_url "${cluster_url}" \
      '{
        platform: {url: $platform_url},
        cluster: {url: $cluster_url}
      }'
  )"

  jq -n \
    --arg namespace "${status_namespace}" \
    --arg name "${status_configmap}" \
    --arg cluster_name "${cluster_name}" \
    --arg schema_version "${schema_version}" \
    --arg repositories_json "${repositories_json}" \
    --arg section_data "${section_data}" \
    --argjson sections "${sections_json}" \
    '{
      apiVersion: "v1",
      kind: "ConfigMap",
      metadata: {
        name: $name,
        namespace: $namespace,
        labels: {
          "app.kubernetes.io/name": "pve-k8s-talos-deployment-status",
          "app.kubernetes.io/instance": $cluster_name,
          "app.kubernetes.io/component": "deployment-metadata",
          "app.kubernetes.io/part-of": "pve-k8s-talos",
          "app.kubernetes.io/managed-by": "infrastructure",
          "pve-k8s-talos/cluster": $cluster_name
        },
        annotations: {
          "pve-k8s-talos/description":
            "Last successful deployment recorded independently for each repository section."
        }
      },
      data: {
        "schema-version": $schema_version,
        "cluster-name": $cluster_name,
        "repositories.json": $repositories_json
      }
    }
    | reduce $sections[] as $section (.;
        .data[($section + ".json")] = $section_data
      )'
}

apply_status_manifest() {
  local manifest_path="$1"
  local existing_resource
  local patch_path

  existing_resource="$(
    "${kubectl_bin}" -n "${status_namespace}" get configmap "${status_configmap}" \
      --ignore-not-found -o name
  )"
  if [[ -z "${existing_resource}" ]]; then
    "${kubectl_bin}" create -f "${manifest_path}" >/dev/null
    message "Created deployment status for cluster ${cluster_name}."
    return
  fi

  patch_path="$(mktemp)"
  jq '{metadata: {labels: .metadata.labels, annotations: .metadata.annotations}, data: .data}' \
    "${manifest_path}" >"${patch_path}"
  if ! "${kubectl_bin}" -n "${status_namespace}" patch configmap "${status_configmap}" \
    --type merge --patch-file "${patch_path}" >/dev/null; then
    rm -f "${patch_path}"
    return 1
  fi
  rm -f "${patch_path}"
  message "Updated deployment status for cluster ${cluster_name}."
}

show_status() {
  "${kubectl_bin}" -n "${status_namespace}" get configmap "${status_configmap}" -o json \
    | jq '
        .data as $data
        | {
            schema_version: $data["schema-version"],
            cluster: $data["cluster-name"],
            repositories: ($data["repositories.json"] | fromjson),
            runtime_state: (
              if $data["runtime-state.json"] then
                ($data["runtime-state.json"] | fromjson)
              else
                null
              end
            ),
            sections: (
              $data
              | to_entries
              | map(
                  select(.key != "repositories.json")
                  | select(.key != "runtime-state.json")
                  | select(.key | endswith(".json"))
                  | {
                      key: (.key | rtrimstr(".json")),
                      value: (.value | fromjson)
                    }
                )
              | from_entries
            )
          }
      '
}

record_runtime_state() {
  local runtime_state_json="$1"
  local patch_path

  if [[ -z "$(
    "${kubectl_bin}" -n "${status_namespace}" get configmap "${status_configmap}" \
      --ignore-not-found -o name
  )" ]]; then
    error "Cannot record runtime state because ${status_namespace}/${status_configmap} does not exist." >&2
    exit 1
  fi

  patch_path="$(mktemp)"
  jq -n \
    --arg runtime_state_json "${runtime_state_json}" \
    '{data: {"runtime-state.json": $runtime_state_json}}' >"${patch_path}"
  if ! "${kubectl_bin}" -n "${status_namespace}" patch configmap "${status_configmap}" \
    --type merge --patch-file "${patch_path}" >/dev/null; then
    rm -f "${patch_path}"
    return 1
  fi
  rm -f "${patch_path}"
  message "Updated runtime state commit for cluster ${cluster_name}."
}

command="${1:-}"
if [[ -z "${command}" ]]; then
  usage >&2
  exit 1
fi
shift

sections_csv=""
section=""
deployment_id=""
platform_commit_override=""
cluster_commit_override=""
platform_dirty_override=""
cluster_dirty_override=""
confirm_aligned=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sections)
      sections_csv="${2:-}"
      shift 2
      ;;
    --section)
      section="${2:-}"
      shift 2
      ;;
    --deployment-id)
      deployment_id="${2:-}"
      shift 2
      ;;
    --platform-commit)
      platform_commit_override="${2:-}"
      shift 2
      ;;
    --cluster-commit)
      cluster_commit_override="${2:-}"
      shift 2
      ;;
    --platform-dirty)
      platform_dirty_override="${2:-}"
      shift 2
      ;;
    --cluster-dirty)
      cluster_dirty_override="${2:-}"
      shift 2
      ;;
    --confirm-aligned)
      confirm_aligned=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${command}" in
  show|baseline|record|record-runtime-state)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    error "Unknown command: ${command}" >&2
    usage >&2
    exit 1
    ;;
esac

require_cmd git
require_cmd jq
require_cmd "${kubectl_bin}"
setup_cluster_context "${script_dir}" ""
require_independent_cluster_repository

if [[ "${command}" == "show" ]]; then
  show_status
  exit 0
fi

platform_url="$(repository_url "${repo_root}" "platform")"
cluster_url="$(repository_url "${cluster_dir}" "cluster")"
timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
sections=()

if [[ "${command}" == "record-runtime-state" ]]; then
  if [[ -z "${deployment_id}" || ! "${deployment_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    error "record-runtime-state requires a safe --deployment-id." >&2
    exit 1
  fi
  if [[ -z "${cluster_commit_override}" ]]; then
    error "record-runtime-state requires --cluster-commit." >&2
    exit 1
  fi
  if [[ -n "${sections_csv}" || -n "${section}" \
    || -n "${platform_commit_override}" || -n "${platform_dirty_override}" \
    || -n "${cluster_dirty_override}" || "${confirm_aligned}" == "true" ]]; then
    error "record-runtime-state only accepts deployment ID and cluster commit provenance." >&2
    exit 1
  fi
  if repository_is_dirty "${cluster_dir}"; then
    error "Cannot record a runtime state commit from a dirty cluster repository." >&2
    exit 1
  fi

  cluster_commit="$(
    resolve_explicit_commit "${cluster_dir}" "cluster" "${cluster_commit_override}"
  )"
  runtime_state_json="$(
    jq -cn \
      --arg commit "${cluster_commit}" \
      --arg recorded_at "${timestamp}" \
      --arg deployment_id "${deployment_id}" \
      '{
        commit: $commit,
        recorded_at: $recorded_at,
        deployment_id: $deployment_id
      }'
  )"
  if [[ "${dry_run}" == "true" ]]; then
    jq . <<<"${runtime_state_json}"
    exit 0
  fi
  record_runtime_state "${runtime_state_json}"
  exit 0
elif [[ "${command}" == "baseline" ]]; then
  if [[ -n "${platform_dirty_override}" || -n "${cluster_dirty_override}" ]]; then
    error "Dirty overrides are only valid with the record command." >&2
    exit 1
  fi
  if [[ "${confirm_aligned}" != "true" ]]; then
    error "baseline requires --confirm-aligned." >&2
    exit 1
  fi
  if [[ -z "${sections_csv}" || ! "${sections_csv}" =~ ^[a-z0-9,-]+$ ]]; then
    error "baseline requires a comma-separated --sections list." >&2
    exit 1
  fi
  IFS=',' read -r -a sections <<< "${sections_csv}"
  for candidate in "${sections[@]}"; do
    if ! is_valid_section "${candidate}"; then
      error "Unknown deployment section: ${candidate}" >&2
      exit 1
    fi
  done

  if [[ -n "${platform_commit_override}" || -n "${cluster_commit_override}" ]]; then
    if [[ -z "${platform_commit_override}" || -z "${cluster_commit_override}" ]]; then
      error "Supply both --platform-commit and --cluster-commit for an explicit baseline." >&2
      exit 1
    fi
    platform_commit="$(
      resolve_explicit_commit "${repo_root}" "platform" "${platform_commit_override}"
    )"
    cluster_commit="$(
      resolve_explicit_commit "${cluster_dir}" "cluster" "${cluster_commit_override}"
    )"
  else
    if repository_is_dirty "${repo_root}" || repository_is_dirty "${cluster_dir}"; then
      error "A baseline from HEAD requires clean platform and cluster repositories." >&2
      exit 1
    fi
    platform_commit="$(current_commit "${repo_root}")"
    cluster_commit="$(current_commit "${cluster_dir}")"
  fi

  section_data="$(
    jq -cn \
      --arg platform_commit "${platform_commit}" \
      --arg cluster_commit "${cluster_commit}" \
      --arg recorded_at "${timestamp}" \
      '{
        revisions: {
          platform: {commit: $platform_commit, dirty: false},
          cluster: {commit: $cluster_commit, dirty: false}
        },
        provenance: "operator-confirmed-baseline",
        recorded_at: $recorded_at,
        deployed_at: null
      }'
  )"
else
  if ! is_valid_section "${section}"; then
    error "record requires a valid --section." >&2
    exit 1
  fi
  if [[ -z "${deployment_id}" || ! "${deployment_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    error "record requires a safe --deployment-id." >&2
    exit 1
  fi
  sections=("${section}")

  if [[ -n "${platform_commit_override}" || -n "${cluster_commit_override}" \
    || -n "${platform_dirty_override}" || -n "${cluster_dirty_override}" ]]; then
    if [[ -z "${platform_commit_override}" || -z "${cluster_commit_override}" \
      || -z "${platform_dirty_override}" || -z "${cluster_dirty_override}" ]]; then
      error "Explicit record provenance requires both commits and both dirty flags." >&2
      exit 1
    fi
    if [[ ! "${platform_dirty_override}" =~ ^(true|false)$ \
      || ! "${cluster_dirty_override}" =~ ^(true|false)$ ]]; then
      error "Dirty flags must be true or false." >&2
      exit 1
    fi
    platform_commit="$(
      resolve_explicit_commit "${repo_root}" "platform" "${platform_commit_override}"
    )"
    cluster_commit="$(
      resolve_explicit_commit "${cluster_dir}" "cluster" "${cluster_commit_override}"
    )"
    platform_dirty="${platform_dirty_override}"
    cluster_dirty="${cluster_dirty_override}"
  else
    platform_commit="$(current_commit "${repo_root}")"
    cluster_commit="$(current_commit "${cluster_dir}")"
    platform_dirty=false
    cluster_dirty=false
    if repository_is_dirty "${repo_root}"; then
      platform_dirty=true
    fi
    if repository_is_dirty "${cluster_dir}"; then
      cluster_dirty=true
    fi
  fi

  section_data="$(
    jq -cn \
      --arg platform_commit "${platform_commit}" \
      --arg cluster_commit "${cluster_commit}" \
      --argjson platform_dirty "${platform_dirty}" \
      --argjson cluster_dirty "${cluster_dirty}" \
      --arg deployed_at "${timestamp}" \
      --arg deployment_id "${deployment_id}" \
      '{
        revisions: {
          platform: {commit: $platform_commit, dirty: $platform_dirty},
          cluster: {commit: $cluster_commit, dirty: $cluster_dirty}
        },
        provenance: "deploy.sh",
        deployed_at: $deployed_at,
        deployment_id: $deployment_id
      }'
  )"
fi

sections_json="$(printf '%s\n' "${sections[@]}" | jq -R . | jq -s .)"
manifest_path="$(mktemp)"
trap 'rm -f "${manifest_path:-}"' EXIT
build_status_manifest \
  "${sections_json}" \
  "${section_data}" \
  "${platform_url}" \
  "${cluster_url}" >"${manifest_path}"

if [[ "${dry_run}" == "true" ]]; then
  jq . "${manifest_path}"
  exit 0
fi

apply_status_manifest "${manifest_path}"
