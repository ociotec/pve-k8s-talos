#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  cluster-state-sync.sh preflight \
    --platform-dir <path> --cluster-dir <path>

  cluster-state-sync.sh persist \
    --platform-dir <path> --cluster-dir <path> \
    --deployment-id <id> --outcome <success|failed|destroyed> \
    [--include-purged-credentials]

Internal helper used by deploy.sh to serialize Git-backed cluster runtime state.
USAGE
}

command="${1:-}"
if [[ -z "${command}" ]]; then
  usage >&2
  exit 1
fi
shift
if [[ "${command}" == "-h" || "${command}" == "--help" ]]; then
  usage
  exit 0
fi

platform_dir=""
cluster_repo_dir=""
deployment_id=""
outcome=""
include_purged_credentials=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform-dir)
      platform_dir="${2:-}"
      shift 2
      ;;
    --cluster-dir)
      cluster_repo_dir="${2:-}"
      shift 2
      ;;
    --deployment-id)
      deployment_id="${2:-}"
      shift 2
      ;;
    --outcome)
      outcome="${2:-}"
      shift 2
      ;;
    --include-purged-credentials)
      include_purged_credentials=true
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
  preflight|persist)
    ;;
  *)
    error "Unknown command: ${command}" >&2
    usage >&2
    exit 1
    ;;
esac

require_cmd git

if [[ -z "${platform_dir}" || -z "${cluster_repo_dir}" ]]; then
  error "--platform-dir and --cluster-dir are required." >&2
  exit 1
fi

platform_dir="$(cd "${platform_dir}" && pwd -P)"
cluster_repo_dir="$(cd "${cluster_repo_dir}" && pwd -P)"

require_repository_root() {
  local path="$1"
  local role="$2"
  local actual_root

  actual_root="$(git -C "${path}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${actual_root}" || "$(cd "${actual_root}" && pwd -P)" != "${path}" ]]; then
    error "${role} must be an independent Git repository root: ${path}" >&2
    exit 1
  fi
}

repository_dirty() {
  local path="$1"
  [[ -n "$(git -C "${path}" status --porcelain=v1 --untracked-files=normal)" ]]
}

require_repository_root "${platform_dir}" "Platform repository"
require_repository_root "${cluster_repo_dir}" "Cluster repository"

if [[ "${command}" == "preflight" ]]; then
  if repository_dirty "${platform_dir}"; then
    error "Platform repository is dirty; commit or discard its changes before deploying." >&2
    exit 1
  fi
  if repository_dirty "${cluster_repo_dir}"; then
    error "Cluster repository is dirty; commit or discard its changes before deploying." >&2
    exit 1
  fi

  platform_branch="$(
    git -C "${platform_dir}" symbolic-ref --quiet --short HEAD || true
  )"
  if [[ -z "${platform_branch}" ]]; then
    error "Platform repository must be on a named branch before deploying." >&2
    exit 1
  fi
  platform_upstream="$(
    git -C "${platform_dir}" rev-parse \
      --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true
  )"
  if [[ -z "${platform_upstream}" ]]; then
    error "Platform branch ${platform_branch} does not have an upstream." >&2
    exit 1
  fi

  message "Checking platform repository ${platform_branch} against ${platform_upstream}..."
  git -C "${platform_dir}" fetch --quiet
  platform_ahead="$(
    git -C "${platform_dir}" rev-list --count "${platform_upstream}..HEAD"
  )"
  platform_behind="$(
    git -C "${platform_dir}" rev-list --count "HEAD..${platform_upstream}"
  )"
  if [[ "${platform_ahead}" -ne 0 || "${platform_behind}" -ne 0 ]]; then
    error "Platform branch ${platform_branch} must match ${platform_upstream} before deploying." >&2
    error "Push or pull the platform repository explicitly, then retry." >&2
    exit 1
  fi

  branch="$(git -C "${cluster_repo_dir}" symbolic-ref --quiet --short HEAD || true)"
  if [[ -z "${branch}" ]]; then
    error "Cluster repository must be on a named branch before deploying." >&2
    exit 1
  fi
  upstream="$(
    git -C "${cluster_repo_dir}" rev-parse \
      --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true
  )"
  if [[ -z "${upstream}" ]]; then
    error "Cluster branch ${branch} does not have an upstream." >&2
    exit 1
  fi

  message "Synchronizing cluster repository ${branch} with ${upstream}..."
  git -C "${cluster_repo_dir}" pull --ff-only --quiet

  if repository_dirty "${cluster_repo_dir}"; then
    error "Cluster repository became dirty after git pull; refusing to deploy." >&2
    exit 1
  fi
  cluster_ahead="$(git -C "${cluster_repo_dir}" rev-list --count "${upstream}..HEAD")"
  if [[ "${cluster_ahead}" -ne 0 ]]; then
    message "Pushing ${cluster_ahead} pending cluster repository commit(s)..."
    git -C "${cluster_repo_dir}" push --quiet
  fi
  exit 0
fi

if [[ -z "${deployment_id}" || ! "${deployment_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  error "persist requires a safe --deployment-id." >&2
  exit 1
fi
case "${outcome}" in
  success|failed|destroyed)
    ;;
  *)
    error "persist requires --outcome success, failed, or destroyed." >&2
    exit 1
    ;;
esac

runtime_file_candidates() {
  local exact_path

  for exact_path in \
    "${cluster_repo_dir}/out/kubeconfig" \
    "${cluster_repo_dir}/out/talosconfig" \
    "${cluster_repo_dir}/out/.talos-bootstrap-complete"; do
    if [[ -f "${exact_path}" ]]; then
      printf '%s\n' "${exact_path}"
    fi
  done
  if [[ -d "${cluster_repo_dir}/out" ]]; then
    find "${cluster_repo_dir}/out" -type f -name terraform.tfstate -print
  fi
}

while IFS= read -r runtime_path; do
  runtime_relative_path="${runtime_path#"${cluster_repo_dir}/"}"
  if ! git -C "${cluster_repo_dir}" ls-files --error-unmatch \
    -- "${runtime_relative_path}" >/dev/null 2>&1 \
    && git -C "${cluster_repo_dir}" check-ignore -q -- "${runtime_relative_path}"; then
    error "Runtime file is ignored and cannot be synchronized: ${runtime_relative_path}" >&2
    error "Update the cluster repository .gitignore before deploying again." >&2
    exit 1
  fi
done < <(runtime_file_candidates | sort -u)

status_args=(
  status
  --porcelain=v1
  --untracked-files=all
  --
  .
  ":(exclude,glob)out/**/terraform.tfstate"
  ":(exclude)out/kubeconfig"
  ":(exclude)out/talosconfig"
  ":(exclude)out/.talos-bootstrap-complete"
)
if [[ "${include_purged_credentials}" == "true" ]]; then
  status_args+=(
    ":(exclude)secrets/credentials.json"
    ":(exclude)secrets/credentials_and_urls.md"
    ":(exclude,glob)certs/**"
  )
fi

unexpected_changes="$(git -C "${cluster_repo_dir}" "${status_args[@]}")"
if [[ -n "${unexpected_changes}" ]]; then
  error "Refusing to commit cluster runtime state because unexpected files changed:" >&2
  while IFS= read -r changed_line; do
    error "  ${changed_line}" >&2
  done <<<"${unexpected_changes}"
  exit 1
fi

if [[ -d "${cluster_repo_dir}/out" \
  || -n "$(git -C "${cluster_repo_dir}" ls-files -- out)" ]]; then
  git -C "${cluster_repo_dir}" add -A -- out
fi
if [[ "${include_purged_credentials}" == "true" ]]; then
  if [[ -d "${cluster_repo_dir}/secrets" \
    || -n "$(git -C "${cluster_repo_dir}" ls-files -- secrets)" ]]; then
    git -C "${cluster_repo_dir}" add -A -- secrets
  fi
  if [[ -d "${cluster_repo_dir}/certs" \
    || -n "$(git -C "${cluster_repo_dir}" ls-files -- certs)" ]]; then
    git -C "${cluster_repo_dir}" add -A -- certs
  fi
fi

if git -C "${cluster_repo_dir}" diff --cached --quiet; then
  message "Cluster runtime state did not change; no Git commit is required."
  exit 0
fi

case "${outcome}" in
  success)
    commit_subject="Record cluster runtime state after ${deployment_id}"
    ;;
  failed)
    commit_subject="Preserve cluster runtime state after failed ${deployment_id}"
    ;;
  destroyed)
    commit_subject="Record destroyed cluster state after ${deployment_id}"
    ;;
esac

git -C "${cluster_repo_dir}" commit --quiet -m "${commit_subject}"
runtime_commit="$(git -C "${cluster_repo_dir}" rev-parse HEAD)"
message "Created cluster runtime state commit ${runtime_commit}."

if ! git -C "${cluster_repo_dir}" push --quiet; then
  error "Cluster runtime state was committed locally but could not be pushed." >&2
  error "Do not deploy from another PC until this commit has been pushed." >&2
  exit 1
fi
message "Pushed cluster runtime state commit to its configured upstream."
