#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: kafka-mass-topic-creator.sh [options] --count N

Creates a batch of Kafka topics in the current cluster, intended for load
simulation. Run it from clusters/<cluster>.

Options:
      --start N        First numeric suffix to create. Default: 1
      --count N        Number of topics to create. Required.
      --prefix PREFIX  Topic name prefix. Default: topic
      --width N        Zero-padding width for the numeric suffix. Default: 5
      --partitions N   Partitions per topic. Default: 1
      --replicas N     Replication factor per topic. Default: 3
      --workers N      Parallel workers to launch. Default: 1
      --threads N      Parallel topic tasks per worker. Default: 5
      --delay-ms N     Sleep between topic creations. Default: 0
      --cluster NAME   Require the current directory to be clusters/NAME.
      --dry-run        Print the commands without creating topics.
      --delete         Delete the generated topics instead of creating them.
  -h, --help           Show this help message.

Notes:
  - The script prefers the cluster's internal Kafka bootstrap server from the
    OpenTofu workspace output. If that is unavailable, it falls back to the
    first Redpanda broker service DNS name.
  - It intentionally creates topics with replication factor 3 to exercise
    leader assignment and replication pressure.
USAGE
}

requested_cluster=""
topic_start=1
topic_count=""
topic_prefix="topic"
topic_width=5
topic_partitions=1
topic_replicas=3
worker_count=1
worker_threads=5
delay_ms=0
dry_run="false"
action="create"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      [[ $# -ge 2 && -n "$2" ]] || { error "--count requires a value"; exit 1; }
      topic_count="$2"
      shift 2
      ;;
    --start)
      [[ $# -ge 2 && -n "$2" ]] || { error "--start requires a value"; exit 1; }
      topic_start="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 && -n "$2" ]] || { error "--prefix requires a value"; exit 1; }
      topic_prefix="$2"
      shift 2
      ;;
    --width)
      [[ $# -ge 2 && -n "$2" ]] || { error "--width requires a value"; exit 1; }
      topic_width="$2"
      shift 2
      ;;
    --partitions)
      [[ $# -ge 2 && -n "$2" ]] || { error "--partitions requires a value"; exit 1; }
      topic_partitions="$2"
      shift 2
      ;;
    --replicas)
      [[ $# -ge 2 && -n "$2" ]] || { error "--replicas requires a value"; exit 1; }
      topic_replicas="$2"
      shift 2
      ;;
    --workers)
      [[ $# -ge 2 && -n "$2" ]] || { error "--workers requires a value"; exit 1; }
      worker_count="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 && -n "$2" ]] || { error "--threads requires a value"; exit 1; }
      worker_threads="$2"
      shift 2
      ;;
    --delay-ms)
      [[ $# -ge 2 && -n "$2" ]] || { error "--delay-ms requires a value"; exit 1; }
      delay_ms="$2"
      shift 2
      ;;
    --cluster)
      [[ $# -ge 2 && -n "$2" ]] || { error "--cluster requires a value"; exit 1; }
      requested_cluster="$2"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --delete)
      action="delete"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

setup_cluster_context "${script_dir}" "${requested_cluster}"
require_cmd kubectl
require_cmd tofu
require_cmd jq

if [[ -z "${topic_count}" ]]; then
  error "--count is required."
  usage >&2
  exit 1
fi

if ! [[ "${topic_count}" =~ ^[0-9]+$ ]] || (( topic_count < 1 )); then
  error "--count must be a positive integer."
  exit 1
fi
if ! [[ "${topic_start}" =~ ^[0-9]+$ ]] || (( topic_start < 1 )); then
  error "--start must be a positive integer."
  exit 1
fi
if ! [[ "${topic_width}" =~ ^[0-9]+$ ]] || (( topic_width < 1 )); then
  error "--width must be a positive integer."
  exit 1
fi
if ! [[ "${topic_partitions}" =~ ^[0-9]+$ ]] || (( topic_partitions < 1 )); then
  error "--partitions must be a positive integer."
  exit 1
fi
if ! [[ "${topic_replicas}" =~ ^[0-9]+$ ]] || (( topic_replicas < 1 )); then
  error "--replicas must be a positive integer."
  exit 1
fi
if ! [[ "${worker_count}" =~ ^[0-9]+$ ]] || (( worker_count < 1 )); then
  error "--workers must be a positive integer."
  exit 1
fi
if ! [[ "${worker_threads}" =~ ^[0-9]+$ ]] || (( worker_threads < 1 )); then
  error "--threads must be a positive integer."
  exit 1
fi
if ! [[ "${delay_ms}" =~ ^[0-9]+$ ]]; then
  error "--delay-ms must be a non-negative integer."
  exit 1
fi

require_cluster_file "${cluster_kubeconfig_path}" "cluster kubeconfig"

workspace_has_state() {
  local workspace="$1"
  [[ -f "${workspace}/terraform.tfstate" || -f "${workspace}/terraform.tfstate.backup" ]]
}

output_raw() {
  local output_name="$1"
  local output

  if ! workspace_has_state "${cluster_kafka_workspace}"; then
    return 0
  fi

  if output="$(tofu -chdir="${cluster_kafka_workspace}" output -raw "${output_name}" 2>&1)"; then
    printf "%s" "${output}"
    return 0
  fi

  case "${output}" in
    *"No outputs found"*|*"output variable requested could not be found"*|*"No output named"*|*'Output "'*'" not found'*)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

output_json() {
  local output_name="$1"
  local output

  if ! workspace_has_state "${cluster_kafka_workspace}"; then
    return 0
  fi

  if output="$(tofu -chdir="${cluster_kafka_workspace}" output -json "${output_name}" 2>&1)"; then
    printf "%s" "${output}"
    return 0
  fi

  case "${output}" in
    *"No outputs found"*|*"output variable requested could not be found"*|*"No output named"*|*'Output "'*'" not found'*)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

kafka_namespace="$(output_raw redpanda_namespace)"
if [[ -z "${kafka_namespace}" || "${kafka_namespace}" == "null" ]]; then
  kafka_namespace="kafka"
fi

bootstrap_server="$(output_json kafka_listener_bootstrap | jq -r '
  if type == "object" then
    (.internal.bootstrap_server //
     ([to_entries[] | select(.value.scope == "cluster-internal") | .value.bootstrap_server][0]) //
     empty)
  else
    empty
  end
' 2>/dev/null || true)"

if [[ -z "${bootstrap_server}" ]]; then
  bootstrap_server="redpanda-0.redpanda.${kafka_namespace}.svc.cluster.local:9092"
fi

if [[ "${topic_replicas}" -ne 3 ]]; then
  error "This simulator is intended for replication factor 3; got ${topic_replicas}."
  exit 1
fi

if [[ "${topic_partitions}" -gt 1 ]]; then
  message "Creating topics with more than 1 partition increases the load substantially."
fi
parallelism="$((worker_count * worker_threads))"

topic_name_for_index() {
  local index="$1"
  printf "%s%0*d" "${topic_prefix}" "${topic_width}" "${index}"
}

rpk_cmd() {
  kubectl --kubeconfig "${cluster_kubeconfig_path}" -n "${kafka_namespace}" exec redpanda-0 -c redpanda -- \
    rpk -X "brokers=${bootstrap_server}" "$@"
}

start_index=1
start_index="${topic_start}"
end_index="$((topic_start + topic_count - 1))"
start_topic="$(topic_name_for_index "${start_index}")"
end_topic="$(topic_name_for_index "${end_index}")"

if [[ "${dry_run}" == "true" ]]; then
  if [[ "${action}" == "delete" ]]; then
    printf "kubectl --kubeconfig %s -n %s exec redpanda-0 -c redpanda -- sh -ec '<batch delete %s topics from %s to %s>'\n" \
      "${cluster_kubeconfig_path}" "${kafka_namespace}" "${topic_count}" "${start_topic}" "${end_topic}"
  else
    printf "kubectl --kubeconfig %s -n %s exec redpanda-0 -c redpanda -- sh -ec '<batch create %s topics from %s to %s>'\n" \
      "${cluster_kubeconfig_path}" "${kafka_namespace}" "${topic_count}" "${start_topic}" "${end_topic}"
  fi
  exit 0
fi

run_topic_batch() {
  local op="$1"
  local extra_args="$2"
  local op_verb="$3"
  local range_start="$4"
  local range_end="$5"
  local worker_id="$6"
  local thread_id="$7"

  message "Submitting a single in-pod batch to ${op_verb} topics $(topic_name_for_index "${range_start}")..$(topic_name_for_index "${range_end}")."
  kubectl --kubeconfig "${cluster_kubeconfig_path}" -n "${kafka_namespace}" exec redpanda-0 -c redpanda -- sh -ec "
  set -eu
  start=${range_start}
  end=${range_end}
  width=${topic_width}
  prefix=${topic_prefix}
  brokers=${bootstrap_server}
  total=\$((end - start + 1))
  done_count=0
  worker_id=${worker_id}
  thread_id=${thread_id}

  i=\${start}
  while [ \"\${i}\" -le \"\${end}\" ]; do
    topic=\$(printf '%s%0*d' \"\${prefix}\" \"\${width}\" \"\${i}\")
    if ! output=\$(rpk -X \"brokers=\${brokers}\" topic ${op} \"\${topic}\" ${extra_args} 2>&1); then
      ts=\$(date -Is)
      err_line=\$(printf '[%s] worker=%s thread=%s op=%s topic=%s index=%s error=%s\n' \"\${ts}\" \"\${worker_id}\" \"\${thread_id}\" \"${op_verb}\" \"\${topic}\" \"\${i}\" \"\${output}\")
      printf '%s' \"\${err_line}\" >&2
      if [[ \"\${op_verb}\" == \"delete\" ]]; then
        i=\$((i + 1))
        continue
      fi
      exit 1
    fi
    done_count=\$((done_count + 1))
    printf '.'
    i=\$((i + 1))
  done
"
}

run_parallel_batches() {
  local op="$1"
  local extra_args="$2"
  local op_verb="$3"
  local total="$4"
  local parallel="$5"
  local base_start="$6"
  local chunk_size="$(( (total + parallel - 1) / parallel ))"
  local slot=0
  local range_start range_end
  local worker_id thread_id
  local -a pids=()

  while (( slot < parallel )); do
    range_start="$((base_start + slot * chunk_size))"
    if (( range_start > end_index )); then
      break
    fi
    range_end="$((range_start + chunk_size - 1))"
    if (( range_end > end_index )); then
      range_end="${end_index}"
    fi
    worker_id="$((slot / worker_threads + 1))"
    thread_id="$((slot % worker_threads + 1))"
    run_topic_batch "${op}" "${extra_args}" "${op_verb}" "${range_start}" "${range_end}" "${worker_id}" "${thread_id}" &
    pids+=("$!")
    slot=$((slot + 1))
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "${pid}"
  done
}

if [[ "${action}" == "delete" ]]; then
  run_parallel_batches "delete" "" "delete" "${topic_count}" "${parallelism}" "${start_index}"
else
  run_parallel_batches "create" "--partitions ${topic_partitions} --replicas ${topic_replicas} --if-not-exists" "create" "${topic_count}" "${parallelism}" "${start_index}"
fi

message "Processed ${topic_count} topics with prefix ${topic_prefix}."
