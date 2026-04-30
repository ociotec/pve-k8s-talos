#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  render-k8s-nodes.sh [--kubeconfig <path>]
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

kubeconfig_arg=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      kubeconfig_arg=(--kubeconfig "$2")
      shift 2
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

require_cmd kubectl
require_cmd jq
require_cmd awk

kubectl "${kubeconfig_arg[@]}" get nodes -o json \
  | jq -r '
      def ready_status:
        ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") as $ready
        | if $ready == "True" then "Ready"
          elif $ready == "False" then "NotReady"
          else "Unknown"
          end;

      def node_roles:
        ([.metadata.labels
          | to_entries[]
          | select(.key | startswith("node-role.kubernetes.io/"))
          | (.key | split("/")[1])
          | if . == "" then "<none>" else . end] | unique | sort) as $roles
        | if ($roles | length) > 0 then
            ($roles | join(","))
          else
            (.metadata.labels["kubernetes.io/role"] // "<none>")
          end;

      def internal_ip:
        ([.status.addresses[]? | select(.type == "InternalIP") | .address][0] // "");

      def render_age:
        (now - (.metadata.creationTimestamp | fromdateiso8601)) as $seconds
        | if $seconds >= 86400 then
            "\(($seconds / 86400 | floor))d"
          elif $seconds >= 3600 then
            "\(($seconds / 3600 | floor))h"
          else
            "\(($seconds / 60 | floor))m"
          end;

      [
        "NAME",
        "STATUS",
        "ROLES",
        "AGE",
        "INTERNAL-IP",
        "VERSION",
        "OS-IMAGE",
        "KERNEL-VERSION",
        "CONTAINER-RUNTIME",
        "MAX-PODS"
      ],
      (
        .items
        | sort_by(.metadata.name)[]
        | [
            .metadata.name,
            ready_status,
            node_roles,
            render_age,
            internal_ip,
            .status.nodeInfo.kubeletVersion,
            .status.nodeInfo.osImage,
            .status.nodeInfo.kernelVersion,
            .status.nodeInfo.containerRuntimeVersion,
            .status.capacity.pods
          ]
      )
      | @tsv
    ' \
  | awk -F'\t' '
      {
        rows = NR
        cols = NF
        for (i = 1; i <= NF; i++) {
          data[NR, i] = $i
          if (length($i) > width[i]) {
            width[i] = length($i)
          }
        }
      }
      END {
        for (r = 1; r <= rows; r++) {
          line = ""
          for (c = 1; c <= cols; c++) {
            line = line sprintf("%-*s", width[c], data[r, c])
            if (c < cols) {
              line = line "  "
            }
          }
          print line
        }
      }
    '
