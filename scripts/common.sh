#!/usr/bin/env bash
set -euo pipefail

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
