#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'USAGE'
Usage: kafka-car-log-producer.sh [options]

Deploys a small in-cluster producer that writes Avro-encoded car events to
Kafka topic "car" at 10 events per second. Run it from clusters/<cluster>.

Options:
      --delete         Remove the producer Deployment and ConfigMap.
      --name NAME      Kubernetes object name. Default: car-log-producer.
      --cluster NAME   Require the current directory to be clusters/NAME.
  -h, --help           Show this help message.
USAGE
}

action="apply"
app_name="car-log-producer"
requested_cluster=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)
      action="delete"
      shift
      ;;
    --name)
      if [[ $# -lt 2 || -z "$2" ]]; then
        error "--name requires a value"
        exit 1
      fi
      app_name="$2"
      shift 2
      ;;
    --cluster)
      if [[ $# -lt 2 || -z "$2" ]]; then
        error "--cluster requires a value"
        exit 1
      fi
      requested_cluster="$2"
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

setup_cluster_context "${script_dir}" "${requested_cluster}"
require_cmd kubectl
require_cmd tofu
require_cmd jq
require_cmd awk
require_cmd mktemp

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
      error "Failed to read OpenTofu output ${output_name} in ${cluster_kafka_workspace}. Output:" >&2
      printf "%s\n" "${output}" >&2
      return 1
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
      error "Failed to read OpenTofu output ${output_name} in ${cluster_kafka_workspace}. Output:" >&2
      printf "%s\n" "${output}" >&2
      return 1
      ;;
  esac
}

require_cluster_file "${cluster_kubeconfig_path}" "cluster kubeconfig"

kafka_namespace="$(output_raw redpanda_namespace)"
if [[ -z "${kafka_namespace}" || "${kafka_namespace}" == "null" ]]; then
  kafka_namespace="kafka"
fi

if [[ "${action}" == "delete" ]]; then
  kubectl --kubeconfig "${cluster_kubeconfig_path}" -n "${kafka_namespace}" delete deployment "${app_name}" --ignore-not-found
  kubectl --kubeconfig "${cluster_kubeconfig_path}" -n "${kafka_namespace}" delete configmap "${app_name}" --ignore-not-found
  message "Removed ${app_name} from namespace ${kafka_namespace}."
  exit 0
fi

kafka_listener_bootstrap="$(output_json kafka_listener_bootstrap)"
bootstrap_server="$(
  jq -r '
    if type == "object" then
      (.internal.bootstrap_server //
       ([to_entries[] | select(.value.scope == "cluster-internal") | .value.bootstrap_server][0]) //
       empty)
    else
      empty
    end
  ' <<< "${kafka_listener_bootstrap}"
)"

schema_registry_url="$(output_raw schema_registry_service_url)"
redpanda_admin_url="$(output_raw redpanda_admin_service_url)"
broker_count="$(output_raw redpanda_broker_count)"

if [[ -z "${bootstrap_server}" ]]; then
  error "Cannot find an internal Kafka bootstrap server in kafka_listener_bootstrap output."
  exit 1
fi
if [[ -z "${schema_registry_url}" ]]; then
  error "Cannot find schema_registry_service_url output."
  exit 1
fi
if [[ -z "${redpanda_admin_url}" ]]; then
  error "Cannot find redpanda_admin_service_url output."
  exit 1
fi
if [[ -z "${broker_count}" || "${broker_count}" == "null" ]]; then
  broker_count="3"
fi
if ! [[ "${broker_count}" =~ ^[0-9]+$ ]] || (( broker_count < 3 )); then
  error "Kafka car topic requires at least 3 brokers; got ${broker_count}."
  exit 1
fi
topic_replicas="3"

redpanda_image=""
if [[ -r "${cluster_kafka_constants_path}" ]]; then
  redpanda_image="$(awk -F'"' '/^[[:space:]]*redpanda_image[[:space:]]*=/{print $2; exit}' "${cluster_kafka_constants_path}")"
fi
if [[ -z "${redpanda_image}" ]]; then
  redpanda_image="docker.redpanda.com/redpandadata/redpanda:v26.1.6"
fi
rollout_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

producer_script="${tmp_dir}/produce.sh"
cat > "${producer_script}" <<'PRODUCER'
#!/usr/bin/env sh
set -eu

TOPIC="${TOPIC:-car}"
SCHEMA_SUBJECT="${SCHEMA_SUBJECT:-car-value}"
PARTITIONS="${PARTITIONS:-3}"
REPLICAS="${REPLICAS:-3}"
EVENT_INTERVAL_SECONDS="${EVENT_INTERVAL_SECONDS:-0.1}"
RETENTION_MS="${RETENTION_MS:-604800000}"

if [ "${REPLICAS}" -lt 3 ]; then
  echo "Topic ${TOPIC} requires at least 3 replicas; got ${REPLICAS}." >&2
  exit 1
fi

strip_scheme() {
  printf "%s" "$1" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#/$##'
}

REGISTRY_ENDPOINTS="$(strip_scheme "${REGISTRY_HOSTS}")"
ADMIN_ENDPOINTS="$(strip_scheme "${ADMIN_HOSTS}")"

cat > /tmp/car-value.avsc <<'AVRO'
{
  "type": "record",
  "name": "car",
  "fields": [
    { "name": "model", "type": "string" },
    { "name": "make", "type": "string" },
    { "name": "year", "type": "float" }
  ]
}
AVRO

rpk_cmd() {
  rpk \
    -X "brokers=${BROKERS}" \
    -X "registry.hosts=${REGISTRY_ENDPOINTS}" \
    -X "admin.hosts=${ADMIN_ENDPOINTS}" \
    "$@"
}

if ! rpk_cmd topic describe "${TOPIC}" >/dev/null 2>&1; then
  rpk_cmd topic create "${TOPIC}" \
    --if-not-exists \
    --partitions "${PARTITIONS}" \
    --replicas "${REPLICAS}" \
    -c cleanup.policy=delete \
    -c "retention.ms=${RETENTION_MS}"
fi

if rpk_cmd registry schema get "${SCHEMA_SUBJECT}" --schema-version latest --print-schema >/tmp/registered-car-value.avsc 2>/dev/null; then
  if ! rpk_cmd registry schema get "${SCHEMA_SUBJECT}" --schema /tmp/car-value.avsc --type avro >/dev/null 2>&1; then
    echo "Schema Registry subject ${SCHEMA_SUBJECT} exists, but it is not the expected car-value schema." >&2
    echo "Registered schema:" >&2
    cat /tmp/registered-car-value.avsc >&2
    exit 1
  fi
else
  rpk_cmd registry schema create "${SCHEMA_SUBJECT}" --schema /tmp/car-value.avsc --type avro >/dev/null
  rpk_cmd registry schema get "${SCHEMA_SUBJECT}" --schema-version latest --print-schema >/tmp/registered-car-value.avsc
fi

rand_u16() {
  od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]'
}

pick_word() {
  set -- $1
  count=$#
  index=$(( $(rand_u16) % count + 1 ))
  eval "printf '%s' \"\${${index}}\""
}

plate_letter() {
  letters="BCDFGHJKLMNPRSTVWXYZ"
  index=$(( $(rand_u16) % ${#letters} + 1 ))
  printf "%s" "${letters}" | cut -c "${index}"
}

generate_plate() {
  number="$(printf "%04d" $(( $(rand_u16) % 10000 )))"
  printf "%s%s%s%s" "${number}" "$(plate_letter)" "$(plate_letter)" "$(plate_letter)"
}

generate_events() {
  makes="SEAT Renault Peugeot Citroen Ford Opel Volkswagen Toyota"
  models="Ibiza Leon Clio Megane 308 C4 Focus Corsa Golf Corolla"

  while :; do
    plate="$(generate_plate)"
    make="$(pick_word "${makes}")"
    model="$(pick_word "${models}")"
    year="$(( 2000 + $(rand_u16) % 27 )).0"

    touch /tmp/car-producer-heartbeat
    printf '%s {"model":"%s","make":"%s","year":%s}\n' \
      "${plate}" "${model}" "${make}" "${year}"
    sleep "${EVENT_INTERVAL_SECONDS}"
  done
}

touch /tmp/car-producer-heartbeat
generate_events | rpk_cmd topic produce "${TOPIC}" --schema-id=topic -f '%k{re#[0-9]{4}[BCDFGHJKLMNPRSTVWXYZ]{3}#} %v{json}\n' --output-format ''
PRODUCER

kubectl --kubeconfig "${cluster_kubeconfig_path}" -n "${kafka_namespace}" create configmap "${app_name}" \
  --from-file=produce.sh="${producer_script}" \
  --dry-run=client \
  -o yaml \
  | kubectl --kubeconfig "${cluster_kubeconfig_path}" apply -f -

cat <<YAML | kubectl --kubeconfig "${cluster_kubeconfig_path}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${app_name}
  namespace: ${kafka_namespace}
  labels:
    app: ${app_name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${app_name}
  template:
    metadata:
      labels:
        app: ${app_name}
      annotations:
        car-log-producer.gcs.gmv.es/rollout-started-at: "${rollout_started_at}"
    spec:
      terminationGracePeriodSeconds: 20
      containers:
        - name: producer
          image: ${redpanda_image}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - /opt/car-producer/produce.sh
          env:
            - name: TOPIC
              value: "car"
            - name: SCHEMA_SUBJECT
              value: "car-value"
            - name: BROKERS
              value: "${bootstrap_server}"
            - name: REGISTRY_HOSTS
              value: "${schema_registry_url}"
            - name: ADMIN_HOSTS
              value: "${redpanda_admin_url}"
            - name: PARTITIONS
              value: "3"
            - name: REPLICAS
              value: "${topic_replicas}"
            - name: EVENT_INTERVAL_SECONDS
              value: "0.1"
            - name: RETENTION_MS
              value: "604800000"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          startupProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - 'test -f /tmp/car-producer-heartbeat'
            periodSeconds: 2
            failureThreshold: 30
            timeoutSeconds: 1
            successThreshold: 1
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - 'test -f /tmp/car-producer-heartbeat && [ \$(( \$(date +%s) - \$(stat -c %Y /tmp/car-producer-heartbeat) )) -lt 10 ]'
            periodSeconds: 5
            failureThreshold: 3
            timeoutSeconds: 1
            successThreshold: 1
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - 'test -f /tmp/car-producer-heartbeat && [ \$(( \$(date +%s) - \$(stat -c %Y /tmp/car-producer-heartbeat) )) -lt 30 ]'
            periodSeconds: 10
            failureThreshold: 3
            timeoutSeconds: 1
            successThreshold: 1
          volumeMounts:
            - name: producer-script
              mountPath: /opt/car-producer
              readOnly: true
      volumes:
        - name: producer-script
          configMap:
            name: ${app_name}
            defaultMode: 0555
YAML

message "Deployed ${app_name} in namespace ${kafka_namespace}."
message "Logs: kubectl --kubeconfig ${cluster_kubeconfig_path} -n ${kafka_namespace} logs deploy/${app_name} -f"
