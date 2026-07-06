#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scale-benchmarks-to-target.sh --cluster <cluster> [--cpu <percent>] [--memory <percent>] [--apply]
  scale-benchmarks-to-target.sh --cluster <cluster> --stop [--apply]

Scale CPU and memory benchmark deployments so current Kubernetes pod usage moves
toward the requested percentage of schedulable node allocatable capacity.

Run from clusters/<cluster>, preferably with:
  direnv exec . ../../scripts/scale-benchmarks-to-target.sh --cluster <cluster> --cpu 90 --memory 80

Options:
  --cluster <cluster>       Cluster directory name. Must match the current cluster directory.
  --cpu <percent>           Target total pod CPU usage as percent of schedulable allocatable CPU.
  --memory <percent>        Target total pod memory usage as percent of schedulable allocatable memory.
  --ram <percent>           Alias for --memory.
  --stop                    Scale CPU and memory benchmark deployments to zero replicas.
  --apply                   Apply the calculated scale changes. Defaults to dry-run.
  --dry-run                 Print the calculated scale changes without applying them.
  --include-tainted-nodes   Include nodes with NoSchedule/NoExecute taints in capacity.
  --namespace <namespace>   Benchmark namespace. Defaults to benchmark.
  -h, --help                Show this help.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${script_dir}/common.sh"

requested_cluster=""
target_cpu_percent=""
target_memory_percent=""
apply=false
stop=false
include_tainted_nodes=false
benchmark_namespace="benchmark"

require_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "${value}" || "${value}" == --* ]]; then
    error "Missing value for ${option}"
    usage >&2
    exit 1
  fi
}

validate_percent() {
  local option="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    error "${option} must be a number from 0 to 100."
    exit 1
  fi

  if ! awk -v value="${value}" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
    error "${option} must be between 0 and 100."
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      require_value "$1" "${2:-}"
      requested_cluster="$2"
      shift 2
      ;;
    --cpu)
      require_value "$1" "${2:-}"
      target_cpu_percent="$2"
      shift 2
      ;;
    --memory|--ram)
      require_value "$1" "${2:-}"
      target_memory_percent="$2"
      shift 2
      ;;
    --stop)
      stop=true
      shift
      ;;
    --apply)
      apply=true
      shift
      ;;
    --dry-run)
      apply=false
      shift
      ;;
    --include-tainted-nodes)
      include_tainted_nodes=true
      shift
      ;;
    --namespace)
      require_value "$1" "${2:-}"
      benchmark_namespace="$2"
      shift 2
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

if [[ "${stop}" != "true" && -z "${target_cpu_percent}" && -z "${target_memory_percent}" ]]; then
  error "Set --cpu, --memory, or --stop."
  usage >&2
  exit 1
fi

if [[ "${stop}" == "true" ]] && [[ -n "${target_cpu_percent}" || -n "${target_memory_percent}" ]]; then
  error "--stop cannot be combined with --cpu or --memory."
  exit 1
fi

if [[ -n "${target_cpu_percent}" ]]; then
  validate_percent "--cpu" "${target_cpu_percent}"
fi

if [[ -n "${target_memory_percent}" ]]; then
  validate_percent "--memory" "${target_memory_percent}"
fi

setup_cluster_context "${BASH_SOURCE[0]}" "${requested_cluster}"

require_cmd kubectl
require_cmd jq
require_cmd awk
require_cluster_file "${cluster_kubeconfig_path}" "cluster kubeconfig"

kubectl_args=(--kubeconfig "${cluster_kubeconfig_path}")

run_kubectl() {
  kubectl "${kubectl_args[@]}" "$@"
}

discover_benchmark_deployments() {
  local deployments_json="$1"
  local cpu_count
  local memory_count

  mapfile -t cpu_deployments < <(
    printf '%s' "${deployments_json}" \
      | jq -r '
          .items[]
          | select(any(.spec.template.spec.containers[]?; ((.args // []) | index("--cpu") != null)))
          | .metadata.name
        '
  )
  mapfile -t memory_deployments < <(
    printf '%s' "${deployments_json}" \
      | jq -r '
          .items[]
          | select(any(.spec.template.spec.containers[]?; ((.args // []) | index("--vm") != null and index("--vm-bytes") != null)))
          | .metadata.name
        '
  )

  cpu_count="${#cpu_deployments[@]}"
  memory_count="${#memory_deployments[@]}"

  if [[ "${cpu_count}" -ne 1 ]]; then
    error "Expected exactly one CPU benchmark deployment in namespace ${benchmark_namespace}; found ${cpu_count}."
    exit 1
  fi

  if [[ "${memory_count}" -ne 1 ]]; then
    error "Expected exactly one memory benchmark deployment in namespace ${benchmark_namespace}; found ${memory_count}."
    exit 1
  fi

  cpu_workload="${cpu_deployments[0]}"
  memory_workload="${memory_deployments[0]}"
}

quantity_jq='
  def cpu_cores:
    tostring as $q
    | if ($q | endswith("n")) then (($q | sub("n$"; "")) | tonumber) / 1000000000
      elif ($q | endswith("u")) then (($q | sub("u$"; "")) | tonumber) / 1000000
      elif ($q | endswith("m")) then (($q | sub("m$"; "")) | tonumber) / 1000
      else ($q | tonumber)
      end;

  def memory_bytes:
    tostring as $q
    | if ($q | test("^[0-9]+([.][0-9]+)?Ki$")) then (($q | sub("Ki$"; "")) | tonumber) * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?Mi$")) then (($q | sub("Mi$"; "")) | tonumber) * 1024 * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?Gi$")) then (($q | sub("Gi$"; "")) | tonumber) * 1024 * 1024 * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?Ti$")) then (($q | sub("Ti$"; "")) | tonumber) * 1024 * 1024 * 1024 * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?Pi$")) then (($q | sub("Pi$"; "")) | tonumber) * 1024 * 1024 * 1024 * 1024 * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?Ei$")) then (($q | sub("Ei$"; "")) | tonumber) * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
      elif ($q | test("^[0-9]+([.][0-9]+)?K$")) then (($q | sub("K$"; "")) | tonumber) * 1000
      elif ($q | test("^[0-9]+([.][0-9]+)?M$")) then (($q | sub("M$"; "")) | tonumber) * 1000 * 1000
      elif ($q | test("^[0-9]+([.][0-9]+)?G$")) then (($q | sub("G$"; "")) | tonumber) * 1000 * 1000 * 1000
      elif ($q | test("^[0-9]+([.][0-9]+)?T$")) then (($q | sub("T$"; "")) | tonumber) * 1000 * 1000 * 1000 * 1000
      else ($q | tonumber)
      end;
'

get_cpu_unit_cores() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]
          | select(.metadata.name == $workload)
          | .spec.template.spec.containers[]?
          | select((.args // []) | index("--cpu") != null)
          | (.resources.limits.cpu // .resources.requests.cpu // empty)
          | cpu_cores
        ][0] // empty
      ' --arg workload "${workload}"
}

get_memory_unit_bytes() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r '
        def arg_after($flag):
          (.args // []) as $args
          | ($args | index($flag)) as $index
          | if $index == null then empty else $args[$index + 1] end;

        [
          .items[]
          | select(.metadata.name == $workload)
          | .spec.template.spec.containers[]?
          | select((.args // []) | index("--vm-bytes") != null)
          | arg_after("--vm-bytes")
          | tonumber
        ][0] // empty
      ' --arg workload "${workload}"
}

get_current_replicas() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r '
        [
          .items[]
          | select(.metadata.name == $workload)
          | (.spec.replicas // 0)
        ][0] // 0
      ' --arg workload "${workload}"
}

get_available_replicas() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r '
        [
          .items[]
          | select(.metadata.name == $workload)
          | (.status.availableReplicas // 0)
        ][0] // 0
      ' --arg workload "${workload}"
}

get_cpu_workload_memory_request_bytes() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]
          | select(.metadata.name == $workload)
          | .spec.template.spec.containers[]?
          | select((.args // []) | index("--cpu") != null)
          | (.resources.requests.memory // "0")
          | memory_bytes
        ][0] // 0
      ' --arg workload "${workload}"
}

get_memory_workload_cpu_request_cores() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]
          | select(.metadata.name == $workload)
          | .spec.template.spec.containers[]?
          | select((.args // []) | index("--vm") != null and index("--vm-bytes") != null)
          | (.resources.requests.cpu // "0")
          | cpu_cores
        ][0] // 0
      ' --arg workload "${workload}"
}

get_memory_workload_memory_request_bytes() {
  local deployments_json="$1"
  local workload="$2"

  printf '%s' "${deployments_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]
          | select(.metadata.name == $workload)
          | .spec.template.spec.containers[]?
          | select((.args // []) | index("--vm") != null and index("--vm-bytes") != null)
          | (.resources.requests.memory // "0")
          | memory_bytes
        ][0] // 0
      ' --arg workload "${workload}"
}

get_schedulable_capacity() {
  local nodes_json="$1"
  local resource="$2"

  printf '%s' "${nodes_json}" \
    | jq -r "${quantity_jq}"'
        def ready:
          ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") == "True";

        def benchmark_schedulable:
          ready
          and ((.spec.unschedulable // false) | not)
          and (
            $includeTainted
            or (([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
          );

        [
          .items[]
          | select(benchmark_schedulable)
          | if $resource == "cpu" then (.status.allocatable.cpu | cpu_cores)
            else (.status.allocatable.memory | memory_bytes)
            end
        ] | add // 0
      ' --arg resource "${resource}" --argjson includeTainted "${include_tainted_nodes}"
}

get_schedulable_node_count() {
  local nodes_json="$1"

  printf '%s' "${nodes_json}" \
    | jq -r '
        def ready:
          ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") == "True";

        def benchmark_schedulable:
          ready
          and ((.spec.unschedulable // false) | not)
          and (
            $includeTainted
            or (([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
          );

        [.items[] | select(benchmark_schedulable)] | length
      ' --argjson includeTainted "${include_tainted_nodes}"
}

get_schedulable_free_requests() {
  local nodes_json="$1"
  local pods_json="$2"

  jq -sr "${quantity_jq}"'
    .[0] as $nodes
    | .[1] as $pods
    |

    def ready:
      ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") == "True";

    def benchmark_schedulable:
      ready
      and ((.spec.unschedulable // false) | not)
      and (
        $includeTainted
        or (([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
      );

    def container_request_sum($containers):
      [
        $containers[]?
        | {
            cpu: ((.resources.requests.cpu // "0") | cpu_cores),
            memory: ((.resources.requests.memory // "0") | memory_bytes)
          }
      ]
      | reduce .[] as $request ({cpu: 0, memory: 0};
          .cpu += $request.cpu
          | .memory += $request.memory
        );

    def init_request_max($containers):
      [
        $containers[]?
        | {
            cpu: ((.resources.requests.cpu // "0") | cpu_cores),
            memory: ((.resources.requests.memory // "0") | memory_bytes)
          }
      ]
      | reduce .[] as $request ({cpu: 0, memory: 0};
          .cpu = ([.cpu, $request.cpu] | max)
          | .memory = ([.memory, $request.memory] | max)
        );

    def pod_requests:
      (container_request_sum(.spec.containers // [])) as $regular
      | (init_request_max(.spec.initContainers // [])) as $init
      | {
          cpu: ([$regular.cpu, $init.cpu] | max),
          memory: ([$regular.memory, $init.memory] | max)
        };

    def active_non_benchmark_pod:
      (.status.phase != "Succeeded" and .status.phase != "Failed")
      and (
        (
          .metadata.namespace == $namespace
          and (
            (.metadata.name | startswith($cpuPrefix))
            or (.metadata.name | startswith($memoryPrefix))
          )
        ) | not
      );

    $nodes.items[]
    | select(benchmark_schedulable)
    | . as $node
    | (
        [
          $pods.items[]?
          | select((.spec.nodeName // "") == $node.metadata.name)
          | select(active_non_benchmark_pod)
          | pod_requests
        ]
        | reduce .[] as $request ({cpu: 0, memory: 0};
            .cpu += $request.cpu
            | .memory += $request.memory
          )
      ) as $used
    | [
        $node.metadata.name,
        ([($node.status.allocatable.cpu | cpu_cores) - $used.cpu, 0] | max),
        ([($node.status.allocatable.memory | memory_bytes) - $used.memory, 0] | max)
      ]
    | @tsv
  ' \
    --argjson includeTainted "${include_tainted_nodes}" \
    --arg namespace "${benchmark_namespace}" \
    --arg cpuPrefix "${cpu_workload}-" \
    --arg memoryPrefix "${memory_workload}-" \
    <(printf '%s' "${nodes_json}") \
    <(printf '%s' "${pods_json}")
}

cap_replicas_for_requests() {
  local desired_cpu="$1"
  local desired_memory="$2"
  local free_requests="$3"

  printf '%s\n' "${free_requests}" \
    | awk \
        -v desired_cpu="${desired_cpu}" \
        -v desired_memory="${desired_memory}" \
        -v cpu_cpu="${cpu_unit_cores}" \
        -v cpu_memory="${cpu_request_memory_bytes}" \
        -v memory_cpu="${memory_request_cores}" \
        -v memory_memory="${memory_request_bytes}" '
          {
            node_count += 1
            free_cpu[node_count] = $2
            free_memory[node_count] = $3
          }

          function place(request_cpu, request_memory,    i, selected, selected_memory) {
            selected = 0
            selected_memory = -1
            for (i = 1; i <= node_count; i += 1) {
              if (free_cpu[i] + 0.000000001 >= request_cpu && free_memory[i] >= request_memory) {
                if (free_memory[i] > selected_memory) {
                  selected = i
                  selected_memory = free_memory[i]
                }
              }
            }
            if (selected == 0) {
              return 0
            }
            free_cpu[selected] -= request_cpu
            free_memory[selected] -= request_memory
            return 1
          }

          END {
            for (cpu_replicas = 0; cpu_replicas < desired_cpu; cpu_replicas += 1) {
              if (!place(cpu_cpu, cpu_memory)) {
                break
              }
            }
            for (memory_replicas = 0; memory_replicas < desired_memory; memory_replicas += 1) {
              if (!place(memory_cpu, memory_memory)) {
                break
              }
            }
            printf "%d %d\n", cpu_replicas, memory_replicas
          }
        '
}

get_total_usage() {
  local pod_metrics_json="$1"
  local resource="$2"

  printf '%s' "${pod_metrics_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]?
          | .containers[]?
          | if $resource == "cpu" then (.usage.cpu | cpu_cores)
            else (.usage.memory | memory_bytes)
            end
        ] | add // 0
      ' --arg resource "${resource}"
}

get_benchmark_usage() {
  local pod_metrics_json="$1"
  local resource="$2"

  printf '%s' "${pod_metrics_json}" \
    | jq -r "${quantity_jq}"'
        [
          .items[]?
          | select(.metadata.namespace == $namespace)
          | select((.metadata.name | startswith($cpuPrefix)) or (.metadata.name | startswith($memoryPrefix)))
          | .containers[]?
          | if $resource == "cpu" then (.usage.cpu | cpu_cores)
            else (.usage.memory | memory_bytes)
            end
        ] | add // 0
      ' \
      --arg namespace "${benchmark_namespace}" \
      --arg cpuPrefix "${cpu_workload}-" \
      --arg memoryPrefix "${memory_workload}-" \
      --arg resource "${resource}"
}

ceil_div() {
  local numerator="$1"
  local denominator="$2"

  awk -v numerator="${numerator}" -v denominator="${denominator}" '
    BEGIN {
      if (denominator <= 0 || numerator <= 0) {
        print 0
        exit
      }
      value = numerator / denominator
      rounded = int(value)
      if (value > rounded) {
        rounded += 1
      }
      print rounded
    }
  '
}

subtract_floor_zero() {
  local left="$1"
  local right="$2"

  awk -v left="${left}" -v right="${right}" 'BEGIN { value = left - right; if (value < 0) value = 0; printf "%.9f", value }'
}

percent_of() {
  local value="$1"
  local percent="$2"

  awk -v value="${value}" -v percent="${percent}" 'BEGIN { printf "%.9f", value * percent / 100 }'
}

format_cpu() {
  local value="$1"

  awk -v value="${value}" 'BEGIN {
    if (value >= 1) {
      printf "%.2f cores", value
    } else {
      printf "%.0fm", value * 1000
    }
  }'
}

format_memory() {
  local value="$1"

  awk -v value="${value}" 'BEGIN {
    gib = value / 1024 / 1024 / 1024
    if (gib >= 1) {
      printf "%.2fGi", gib
    } else {
      printf "%.0fMi", value / 1024 / 1024
    }
  }'
}

scale_deployment() {
  local workload="$1"
  local replicas="$2"

  if [[ "${apply}" == "true" ]]; then
    run_kubectl -n "${benchmark_namespace}" scale "deployment/${workload}" --replicas="${replicas}"
  else
    printf 'dry-run: kubectl --kubeconfig %s -n %s scale deployment/%s --replicas=%s\n' \
      "${cluster_kubeconfig_path}" "${benchmark_namespace}" "${workload}" "${replicas}"
  fi
}

if ! deployments_json="$(run_kubectl -n "${benchmark_namespace}" get deployments -o json 2>&1)"; then
  error "Cannot read deployments in namespace ${benchmark_namespace}."
  printf '%s\n' "${deployments_json}" >&2
  exit 1
fi

discover_benchmark_deployments "${deployments_json}"

if [[ "${stop}" == "true" ]]; then
  message "CPU benchmark deployment: ${cpu_workload}"
  message "Memory benchmark deployment: ${memory_workload}"
  scale_deployment "${cpu_workload}" 0
  scale_deployment "${memory_workload}" 0
  exit 0
fi

cpu_unit_cores="$(get_cpu_unit_cores "${deployments_json}" "${cpu_workload}")"
memory_unit_bytes="$(get_memory_unit_bytes "${deployments_json}" "${memory_workload}")"
cpu_request_memory_bytes="$(get_cpu_workload_memory_request_bytes "${deployments_json}" "${cpu_workload}")"
memory_request_cores="$(get_memory_workload_cpu_request_cores "${deployments_json}" "${memory_workload}")"
memory_request_bytes="$(get_memory_workload_memory_request_bytes "${deployments_json}" "${memory_workload}")"
current_cpu_replicas="$(get_current_replicas "${deployments_json}" "${cpu_workload}")"
current_memory_replicas="$(get_current_replicas "${deployments_json}" "${memory_workload}")"
available_cpu_replicas="$(get_available_replicas "${deployments_json}" "${cpu_workload}")"
available_memory_replicas="$(get_available_replicas "${deployments_json}" "${memory_workload}")"

if [[ -n "${target_cpu_percent}" && -z "${cpu_unit_cores}" ]]; then
  error "Could not determine CPU benchmark unit size from deployment/${cpu_workload}."
  exit 1
fi

if [[ -n "${target_memory_percent}" && -z "${memory_unit_bytes}" ]]; then
  error "Could not determine memory benchmark unit size from deployment/${memory_workload}."
  exit 1
fi

if ! nodes_json="$(run_kubectl get nodes -o json 2>&1)"; then
  error "Cannot read Kubernetes nodes."
  printf '%s\n' "${nodes_json}" >&2
  exit 1
fi

if ! pod_metrics_json="$(run_kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods 2>&1)"; then
  error "Cannot read pod metrics from metrics.k8s.io."
  error "Verify metrics-server is deployed and ready before using percentage-based benchmark scaling."
  printf '%s\n' "${pod_metrics_json}" >&2
  exit 1
fi

if ! all_pods_json="$(run_kubectl get pods -A -o json 2>&1)"; then
  error "Cannot read Kubernetes pods for schedulability calculation."
  printf '%s\n' "${all_pods_json}" >&2
  exit 1
fi

schedulable_node_count="$(get_schedulable_node_count "${nodes_json}")"
if [[ "${schedulable_node_count}" -eq 0 ]]; then
  error "No schedulable Ready nodes found for benchmark capacity."
  exit 1
fi

message "Benchmark namespace: ${benchmark_namespace}"
message "Capacity baseline: ${schedulable_node_count} Ready schedulable node(s)"
message "CPU benchmark deployment: ${cpu_workload}"
message "Memory benchmark deployment: ${memory_workload}"

desired_cpu_replicas="${current_cpu_replicas}"
desired_memory_replicas="${current_memory_replicas}"

if [[ -n "${target_cpu_percent}" ]]; then
  allocatable_cpu_cores="$(get_schedulable_capacity "${nodes_json}" cpu)"
  total_cpu_usage="$(get_total_usage "${pod_metrics_json}" cpu)"
  benchmark_cpu_usage="$(get_benchmark_usage "${pod_metrics_json}" cpu)"
  non_benchmark_cpu_usage="$(subtract_floor_zero "${total_cpu_usage}" "${benchmark_cpu_usage}")"
  target_cpu_usage="$(percent_of "${allocatable_cpu_cores}" "${target_cpu_percent}")"
  cpu_deficit="$(subtract_floor_zero "${target_cpu_usage}" "${non_benchmark_cpu_usage}")"
  desired_cpu_replicas="$(ceil_div "${cpu_deficit}" "${cpu_unit_cores}")"

  message "CPU allocatable: $(format_cpu "${allocatable_cpu_cores}")"
  message "CPU current total: $(format_cpu "${total_cpu_usage}")"
  message "CPU current benchmark: $(format_cpu "${benchmark_cpu_usage}")"
  message "CPU target ${target_cpu_percent}%: $(format_cpu "${target_cpu_usage}")"
  message "CPU benchmark unit: $(format_cpu "${cpu_unit_cores}") per replica"
fi

if [[ -n "${target_memory_percent}" ]]; then
  allocatable_memory_bytes="$(get_schedulable_capacity "${nodes_json}" memory)"
  total_memory_usage="$(get_total_usage "${pod_metrics_json}" memory)"
  benchmark_memory_usage="$(get_benchmark_usage "${pod_metrics_json}" memory)"
  non_benchmark_memory_usage="$(subtract_floor_zero "${total_memory_usage}" "${benchmark_memory_usage}")"
  target_memory_usage="$(percent_of "${allocatable_memory_bytes}" "${target_memory_percent}")"
  memory_deficit="$(subtract_floor_zero "${target_memory_usage}" "${non_benchmark_memory_usage}")"
  desired_memory_replicas="$(ceil_div "${memory_deficit}" "${memory_unit_bytes}")"

  message "Memory allocatable: $(format_memory "${allocatable_memory_bytes}")"
  message "Memory current total: $(format_memory "${total_memory_usage}")"
  message "Memory current benchmark: $(format_memory "${benchmark_memory_usage}")"
  message "Memory target ${target_memory_percent}%: $(format_memory "${target_memory_usage}")"
  message "Memory benchmark unit: $(format_memory "${memory_unit_bytes}") per replica"
fi

free_requests="$(get_schedulable_free_requests "${nodes_json}" "${all_pods_json}")"
read -r capped_cpu_replicas capped_memory_replicas < <(cap_replicas_for_requests "${desired_cpu_replicas}" "${desired_memory_replicas}" "${free_requests}")

if (( desired_cpu_replicas >= available_cpu_replicas && capped_cpu_replicas < available_cpu_replicas )); then
  capped_cpu_replicas="${available_cpu_replicas}"
fi

if (( desired_memory_replicas >= available_memory_replicas && capped_memory_replicas < available_memory_replicas )); then
  capped_memory_replicas="${available_memory_replicas}"
fi

if [[ "${capped_cpu_replicas}" != "${desired_cpu_replicas}" || "${capped_memory_replicas}" != "${desired_memory_replicas}" ]]; then
  message "Schedulability cap changed desired replicas from CPU=${desired_cpu_replicas}, memory=${desired_memory_replicas} to CPU=${capped_cpu_replicas}, memory=${capped_memory_replicas} based on per-node requests."
fi

if [[ -n "${target_cpu_percent}" ]]; then
  message "CPU desired replicas: ${capped_cpu_replicas}"
  scale_deployment "${cpu_workload}" "${capped_cpu_replicas}"
fi

if [[ -n "${target_memory_percent}" ]]; then
  message "Memory desired replicas: ${capped_memory_replicas}"
  scale_deployment "${memory_workload}" "${capped_memory_replicas}"
fi
