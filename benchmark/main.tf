terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.1.0"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "../kubeconfig"
  description = "Path to the kubeconfig file."
}

provider "kubernetes" {
  config_path = abspath("${path.module}/${var.kubeconfig_path}")
}

locals {
  benchmark_namespace_value    = try(local.benchmark_namespace, "benchmark")
  benchmark_stress_image_value = try(local.benchmark_stress_image, "ghcr.io/colinianking/stress-ng:9df1b93b7f236617210bbad950bdd01998f381b4")
  benchmark_fio_image_value    = try(local.benchmark_fio_image, "ghcr.io/kvaps/fio:3.38")
  benchmark_kafka_enabled_value = try(local.benchmark_kafka_enabled, false)
  # Benchmark Kafka uses the same Redpanda image and broker bootstrap pattern as
  # the Kafka section, but this module cannot read locals from another module.
  benchmark_kafka_image_value = "docker.redpanda.com/redpandadata/redpanda:v26.1.6"
  benchmark_kafka_bootstrap_value = "redpanda-0.redpanda.kafka.svc.cluster.local:9092,redpanda-1.redpanda.kafka.svc.cluster.local:9092,redpanda-2.redpanda.kafka.svc.cluster.local:9092"
  benchmark_priority_class_name = "benchmark-low"

  benchmark_cpu_vcpus_value    = try(local.benchmark_cpu_vcpus, 2)
  benchmark_cpu_memory_value   = try(local.benchmark_cpu_memory, "256Mi")
  benchmark_cpu_replicas_value = try(local.benchmark_cpu_replicas, 0)
  benchmark_cpu_worker_count   = max(1, floor(local.benchmark_cpu_vcpus_value))
  benchmark_cpu_workload_name  = format("benchmark-cpu-%dvcpus", local.benchmark_cpu_vcpus_value)

  benchmark_memory_gb_value             = try(local.benchmark_memory_gb, 4)
  benchmark_memory_cpu_value            = try(local.benchmark_memory_cpu, "250m")
  benchmark_memory_replicas_value       = try(local.benchmark_memory_replicas, 0)
  benchmark_memory_stress_percent_value = try(local.benchmark_memory_stress_percent, 85)
  benchmark_memory_bytes_value          = local.benchmark_memory_gb_value * 1024 * 1024 * 1024
  benchmark_memory_stress_bytes         = floor(local.benchmark_memory_bytes_value * local.benchmark_memory_stress_percent_value / 100)
  benchmark_memory_workload_name        = format("benchmark-memory-%dgb", local.benchmark_memory_gb_value)

  benchmark_disk_rate_mbs_value        = try(local.benchmark_disk_rate_mbs, 10)
  benchmark_disk_rate_value            = format("%dM", local.benchmark_disk_rate_mbs_value)
  benchmark_disk_cpu_value             = try(local.benchmark_disk_cpu, "100m")
  benchmark_disk_memory_value          = try(local.benchmark_disk_memory, "128Mi")
  benchmark_disk_replicas_value        = try(local.benchmark_disk_replicas, 0)
  benchmark_disk_pvc_size_value        = try(local.benchmark_disk_pvc_size, "2Gi")
  benchmark_disk_fio_file_size_value   = try(local.benchmark_disk_fio_file_size, "1Gi")
  benchmark_disk_block_size_value      = try(local.benchmark_disk_block_size, "1M")
  benchmark_disk_runtime_value         = try(local.benchmark_disk_runtime, "3600")
  benchmark_disk_storage_classes_value = local.benchmark_disk_storage_classes
  benchmark_enabled_disk_storage_classes = {
    for name, storage_class in local.benchmark_disk_storage_classes_value :
    name => storage_class
    if try(storage_class.enabled, true)
  }
  benchmark_disk_pvc_labels = merge(concat([{}], [
    for storage_class_name, _ in local.benchmark_enabled_disk_storage_classes : {
      for ordinal in range(local.benchmark_disk_replicas_value) :
      format("%s-%d", storage_class_name, ordinal) => {
        name     = format("data-benchmark-disk-%s-%dmbs-%d", storage_class_name, local.benchmark_disk_rate_mbs_value, ordinal)
        workload = format("benchmark-disk-%s-%dmbs", storage_class_name, local.benchmark_disk_rate_mbs_value)
      }
    }
  ])...)

  benchmark_kafka_profiles = {
    metadata = {
      topics     = try(local.benchmark_kafka_metadata_topics, 50)
      producers  = try(local.benchmark_kafka_metadata_producers, 1)
      consumers  = try(local.benchmark_kafka_metadata_consumers, 1)
      partitions = try(local.benchmark_kafka_metadata_partitions, 1)
      replicas   = 3
    }
    balanced = {
      topics     = try(local.benchmark_kafka_balanced_topics, 20)
      producers  = try(local.benchmark_kafka_balanced_producers, 2)
      consumers  = try(local.benchmark_kafka_balanced_consumers, 2)
      partitions = try(local.benchmark_kafka_balanced_partitions, 4)
      replicas   = 3
    }
    throughput = {
      topics     = try(local.benchmark_kafka_throughput_topics, 10)
      producers  = try(local.benchmark_kafka_throughput_producers, 4)
      consumers  = try(local.benchmark_kafka_throughput_consumers, 4)
      partitions = try(local.benchmark_kafka_throughput_partitions, 8)
      replicas   = 3
    }
  }
  benchmark_kafka_profile_names = {
    metadata   = "benchmark-kafka-metadata-50t-1p-1c"
    balanced   = "benchmark-kafka-balanced-20t-2p-2c"
    throughput = "benchmark-kafka-throughput-10t-4p-4c"
  }
}

check "benchmark_cpu_integer" {
  assert {
    condition     = local.benchmark_cpu_vcpus_value == floor(local.benchmark_cpu_vcpus_value)
    error_message = "benchmark_cpu_vcpus must be an integer so it can be represented in the workload name."
  }
}

check "benchmark_memory_integer" {
  assert {
    condition     = local.benchmark_memory_gb_value == floor(local.benchmark_memory_gb_value)
    error_message = "benchmark_memory_gb must be an integer so it can be represented in the workload name."
  }
}

check "benchmark_memory_stress_percent_range" {
  assert {
    condition     = local.benchmark_memory_stress_percent_value > 0 && local.benchmark_memory_stress_percent_value <= 100
    error_message = "benchmark_memory_stress_percent must be greater than 0 and less than or equal to 100."
  }
}

check "benchmark_disk_rate_integer" {
  assert {
    condition     = local.benchmark_disk_rate_mbs_value == floor(local.benchmark_disk_rate_mbs_value)
    error_message = "benchmark_disk_rate_mbs must be an integer so it can be represented in the workload name."
  }
}

check "benchmark_kafka_profile_values" {
  assert {
    condition = alltrue([
      for profile in values(local.benchmark_kafka_profiles) :
      profile.topics >= 1 && profile.producers >= 1 && profile.consumers >= 1 && profile.partitions >= 1 && profile.replicas == 3
    ])
    error_message = "Kafka benchmark profile values must be positive and use 3 replicas."
  }
}

resource "kubernetes_manifest" "namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.benchmark_namespace_value
      labels = {
        "pod-security.kubernetes.io/enforce" = "baseline"
        "pod-security.kubernetes.io/audit"   = "baseline"
        "pod-security.kubernetes.io/warn"    = "baseline"
      }
    }
  }
}

resource "kubernetes_manifest" "priority_class" {
  manifest = {
    apiVersion = "scheduling.k8s.io/v1"
    kind       = "PriorityClass"
    metadata = {
      name = local.benchmark_priority_class_name
      labels = {
        "app.kubernetes.io/managed-by" = "infrastructure"
      }
    }
    value            = -1000
    preemptionPolicy = "Never"
    description      = "Low-priority benchmark workloads that should run below normal application pods."
  }
}

resource "kubernetes_manifest" "cpu_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.benchmark_cpu_workload_name
      namespace = local.benchmark_namespace_value
      labels = {
        app = local.benchmark_cpu_workload_name
      }
    }
    spec = {
      replicas = local.benchmark_cpu_replicas_value
      selector = {
        matchLabels = {
          app = local.benchmark_cpu_workload_name
        }
      }
      template = {
        metadata = {
          labels = {
            app = local.benchmark_cpu_workload_name
          }
        }
        spec = {
          terminationGracePeriodSeconds = 5
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "stress-ng"
              image           = local.benchmark_stress_image_value
              imagePullPolicy = "IfNotPresent"
              args = [
                "--cpu",
                tostring(local.benchmark_cpu_worker_count),
                "--cpu-method",
                "all",
                "--timeout",
                "365d",
                "--metrics-brief",
              ]
              resources = {
                requests = {
                  cpu    = tostring(local.benchmark_cpu_vcpus_value)
                  memory = local.benchmark_cpu_memory_value
                }
                limits = {
                  cpu    = tostring(local.benchmark_cpu_vcpus_value)
                  memory = local.benchmark_cpu_memory_value
                }
              }
            },
          ]
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
  ]
}

resource "kubernetes_manifest" "memory_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.benchmark_memory_workload_name
      namespace = local.benchmark_namespace_value
      labels = {
        app = local.benchmark_memory_workload_name
      }
    }
    spec = {
      replicas = local.benchmark_memory_replicas_value
      selector = {
        matchLabels = {
          app = local.benchmark_memory_workload_name
        }
      }
      template = {
        metadata = {
          labels = {
            app = local.benchmark_memory_workload_name
          }
        }
        spec = {
          terminationGracePeriodSeconds = 5
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "stress-ng"
              image           = local.benchmark_stress_image_value
              imagePullPolicy = "IfNotPresent"
              args = [
                "--vm",
                "1",
                "--vm-bytes",
                tostring(local.benchmark_memory_stress_bytes),
                "--vm-keep",
                "--timeout",
                "365d",
                "--metrics-brief",
              ]
              resources = {
                requests = {
                  cpu    = local.benchmark_memory_cpu_value
                  memory = format("%dGi", local.benchmark_memory_gb_value)
                }
                limits = {
                  cpu    = local.benchmark_memory_cpu_value
                  memory = format("%dGi", local.benchmark_memory_gb_value)
                }
              }
            },
          ]
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
  ]
}

resource "kubernetes_manifest" "kafka_deployments" {
  for_each = local.benchmark_kafka_enabled_value ? local.benchmark_kafka_profiles : {}

  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.benchmark_kafka_profile_names[each.key]
      namespace = local.benchmark_namespace_value
      labels = {
        app                            = local.benchmark_kafka_profile_names[each.key]
        "app.kubernetes.io/name"       = local.benchmark_kafka_profile_names[each.key]
        "app.kubernetes.io/instance"   = local.benchmark_kafka_profile_names[each.key]
        "app.kubernetes.io/component"  = "benchmark"
        "app.kubernetes.io/part-of"    = "benchmark"
        "app.kubernetes.io/managed-by" = "infrastructure"
        "pve-k8s-talos/section"        = "benchmark"
      }
    }
    spec = {
      replicas = 0
      selector = {
        matchLabels = {
          app = local.benchmark_kafka_profile_names[each.key]
        }
      }
      template = {
        metadata = {
          labels = {
            app                            = local.benchmark_kafka_profile_names[each.key]
            "app.kubernetes.io/name"       = local.benchmark_kafka_profile_names[each.key]
            "app.kubernetes.io/instance"   = local.benchmark_kafka_profile_names[each.key]
            "app.kubernetes.io/component"  = "benchmark"
            "app.kubernetes.io/part-of"    = "benchmark"
            "app.kubernetes.io/managed-by" = "infrastructure"
            "pve-k8s-talos/section"        = "benchmark"
          }
        }
        spec = {
          terminationGracePeriodSeconds = 300
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "benchmark-kafka"
              image           = local.benchmark_kafka_image_value
              imagePullPolicy = "IfNotPresent"
              command         = ["/bin/sh", "-ec"]
              env = [
                { name = "BENCHMARK_NAME", value = local.benchmark_kafka_profile_names[each.key] },
                { name = "BENCHMARK_TOPICS", value = tostring(each.value.topics) },
                { name = "BENCHMARK_PARTITIONS", value = tostring(each.value.partitions) },
                { name = "BENCHMARK_PRODUCERS", value = tostring(each.value.producers) },
                { name = "BENCHMARK_CONSUMERS", value = tostring(each.value.consumers) },
                { name = "BENCHMARK_REPLICAS", value = tostring(each.value.replicas) },
                { name = "KAFKA_BOOTSTRAP", value = local.benchmark_kafka_bootstrap_value },
              ]
              args = [
                <<-EOT
                set -eu

                replica_index="$$(printf '%s' "$${HOSTNAME}" | cksum | awk '{printf "%03d", ($$1 % 1000)}')"
                topic_prefix="$${BENCHMARK_NAME}-$${replica_index}-"
                cleanup_topics_file="/tmp/benchmark-topics.txt"
                ready_file="/tmp/benchmark-ready"
                heartbeat_file="/tmp/benchmark-heartbeat"
                cleanup_script_file="/tmp/benchmark-cleanup.sh"
                producer_pids=""
                consumer_pids=""
                producer_logs_dir="/tmp/benchmark-producers"
                consumer_logs_dir="/tmp/benchmark-consumers"

                log() {
                  printf '[%s] benchmark=%s replica=%s %s\n' "$$(date -Is)" "$${BENCHMARK_NAME}" "$${replica_index}" "$$*"
                }

                mkdir -p "$${producer_logs_dir}" "$${consumer_logs_dir}"
                log "starting benchmark workload"

                rpk_cmd() {
                  rpk -X "brokers=$${KAFKA_BOOTSTRAP}" "$$@"
                }

                create_topics() {
                  i=1
                  : > "$${cleanup_topics_file}"
                  log "creating $${BENCHMARK_TOPICS} topics with $${BENCHMARK_PARTITIONS} partitions and RF=$${BENCHMARK_REPLICAS}"
                  while [ "$${i}" -le "$${BENCHMARK_TOPICS}" ]; do
                    topic="$$(printf '%s%05d' "$${topic_prefix}" "$${i}")"
                    rpk_cmd topic create "$${topic}" \
                      --if-not-exists \
                      --partitions "$${BENCHMARK_PARTITIONS}" \
                      --replicas "$${BENCHMARK_REPLICAS}" >/dev/null
                    printf '%s\n' "$${topic}" >> "$${cleanup_topics_file}"
                    log "created topic $${topic}"
                    i=$$((i + 1))
                  done
                  log "topic creation complete"
                }

                write_cleanup_script() {
                  cat > "$${cleanup_script_file}" <<'SCRIPT'
#!/bin/sh
set -u

replica_index="$${cleanup_replica_index:-$(printf '%s' "$${HOSTNAME}" | cksum | awk '{printf "%03d", ($$1 % 1000)}')}"
cleanup_topics_file="/tmp/benchmark-topics.txt"
ready_file="/tmp/benchmark-ready"
heartbeat_file="/tmp/benchmark-heartbeat"
producer_pids_file="/tmp/benchmark-producer-pids.txt"
consumer_pids_file="/tmp/benchmark-consumer-pids.txt"
heartbeat_pid_file="/tmp/benchmark-heartbeat.pid"
bootstrap="$${KAFKA_BOOTSTRAP}"
benchmark_name="$${BENCHMARK_NAME}"
topic_prefix="$${benchmark_name}-$${replica_index}-"

log() {
  printf '[%s] benchmark=%s replica=%s %s\n' "$(date -Is)" "$${benchmark_name}" "$${replica_index}" "$*"
}

rpk_cmd() {
  rpk -X "brokers=$${bootstrap}" "$@"
}

stop_pids() {
  file="$1"
  [ -f "$${file}" ] || return 0
  while IFS= read -r pid; do
    [ -n "$${pid}" ] || continue
    kill "$${pid}" >/dev/null 2>&1 || true
  done < "$${file}"
}

wait_pids_to_exit() {
  file="$1"
  [ -f "$${file}" ] || return 0
  while IFS= read -r pid; do
    [ -n "$${pid}" ] || continue
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ! kill -0 "$${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  done < "$${file}"
}

log "cleanup starting"
stop_pids "$${producer_pids_file}"
stop_pids "$${consumer_pids_file}"
if [ -f "$${heartbeat_pid_file}" ]; then
  heartbeat_pid="$(cat "$${heartbeat_pid_file}" 2>/dev/null || true)"
  if [ -n "$${heartbeat_pid}" ]; then
    kill "$${heartbeat_pid}" >/dev/null 2>&1 || true
  fi
fi
rm -f "$${ready_file}" "$${heartbeat_file}"
wait_pids_to_exit "$${producer_pids_file}"
wait_pids_to_exit "$${consumer_pids_file}"

if [ -f "$${cleanup_topics_file}" ]; then
  count="$$(wc -l < "$${cleanup_topics_file}" | tr -d ' ')"
  log "deleting $${count} topic(s)"
  deleted=0
  while IFS= read -r topic; do
    [ -n "$${topic}" ] || continue
    if rpk_cmd topic delete "$${topic}" >/dev/null 2>&1; then
      deleted=$((deleted + 1))
      log "deleted topic $${topic} ($${deleted}/$${count})"
    else
      log "failed to delete topic $${topic} ($${deleted}/$${count}), continuing"
    fi
  done < "$${cleanup_topics_file}"
else
  log "no cleanup topic file present"
fi

log "deleting topics by prefix $${topic_prefix}.*"
rpk_cmd topic delete --regex "$${topic_prefix}.*" >/dev/null 2>&1 || true

sleep 5
log "cleanup complete"
SCRIPT
                  chmod +x "$${cleanup_script_file}"
                }

                start_producers() {
                  i=1
                  log "starting $${BENCHMARK_PRODUCERS} producer(s)"
                  while [ "$${i}" -le "$${BENCHMARK_PRODUCERS}" ]; do
                    assigned_topics="$$(awk -v worker="$${i}" -v workers="$${BENCHMARK_PRODUCERS}" '((NR - 1) % workers) + 1 == worker { print }' "$${cleanup_topics_file}")"
                    if [ -z "$${assigned_topics}" ]; then
                      assigned_topics="$$(head -n 1 "$${cleanup_topics_file}")"
                    fi
                    assigned_topic_count="$$(printf '%s\n' "$${assigned_topics}" | sed '/^$/d' | wc -l | tr -d ' ')"
                    assigned_topics_csv="$$(printf '%s\n' "$${assigned_topics}" | paste -sd ',' -)"
                    log_file="$${producer_logs_dir}/producer-$${i}.log"
                    (
                      trap '' INT TERM
                      while true; do
                        while IFS= read -r topic; do
                          [ -n "$${topic}" ] || continue
                          printf '{"benchmark":"%s","role":"producer","producer_id":%s,"topic":"%s","timestamp":"%s"}\n' \
                            "$${BENCHMARK_NAME}" "$${i}" "$${topic}" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                            | rpk_cmd topic produce "$${topic}" >/dev/null 2>>"$${log_file}"
                        done <<EOF
$${assigned_topics}
EOF
                        sleep 0.1
                      done
                    ) &
                    producer_pid="$$!"
                    producer_pids="$${producer_pids} $${producer_pid}"
                    printf '%s\n' "$${producer_pid}" >> "$${producer_pids_file}"
                    log "started producer $${i} on $${assigned_topic_count} topic(s): $${assigned_topics_csv}"
                    i=$$((i + 1))
                  done
                  log "producer startup complete"
                }

                start_consumers() {
                  i=1
                  log "starting $${BENCHMARK_CONSUMERS} consumer(s)"
                  while [ "$${i}" -le "$${BENCHMARK_CONSUMERS}" ]; do
                    assigned_topics="$$(awk -v worker="$${i}" -v workers="$${BENCHMARK_CONSUMERS}" '((NR - 1) % workers) + 1 == worker { print }' "$${cleanup_topics_file}")"
                    if [ -z "$${assigned_topics}" ]; then
                      assigned_topics="$$(head -n 1 "$${cleanup_topics_file}")"
                    fi
                    assigned_topic_count="$$(printf '%s\n' "$${assigned_topics}" | sed '/^$/d' | wc -l | tr -d ' ')"
                    assigned_topics_csv="$$(printf '%s\n' "$${assigned_topics}" | paste -sd ',' -)"
                    log_file="$${consumer_logs_dir}/consumer-$${i}.log"
                    (
                      trap '' INT TERM
                      topic_args=""
                      while IFS= read -r topic; do
                        [ -n "$${topic}" ] || continue
                        topic_args="$${topic_args} $${topic}"
                      done <<EOF
$${assigned_topics}
EOF
                      # shellcheck disable=SC2086
                      rpk_cmd topic consume $${topic_args} >/dev/null 2>>"$${log_file}"
                    ) &
                    consumer_pid="$$!"
                    consumer_pids="$${consumer_pids} $${consumer_pid}"
                    printf '%s\n' "$${consumer_pid}" >> "$${consumer_pids_file}"
                    log "started consumer $${i} on $${assigned_topic_count} topic(s): $${assigned_topics_csv}"
                    i=$$((i + 1))
                  done
                  log "consumer startup complete"
                }

                heartbeat() {
                  while true; do
                    : > "$${heartbeat_file}"
                    log "heartbeat topics=$${BENCHMARK_TOPICS} producers=$${BENCHMARK_PRODUCERS} consumers=$${BENCHMARK_CONSUMERS}"
                    sleep 20
                  done
                }

                stop_children() {
                  for pid in $${producer_pids} $${consumer_pids}; do
                    kill "$${pid}" >/dev/null 2>&1 || true
                  done
                  if [ -n "$${heartbeat_pid:-}" ]; then
                    kill "$${heartbeat_pid}" >/dev/null 2>&1 || true
                  fi
                }

                cleanup() {
                  cleanup_replica_index="$${replica_index}"
                  export cleanup_replica_index
                  set +e
                  stop_children
                  "$${cleanup_script_file}" || true
                }

                trap 'cleanup; exit 0' INT TERM

                create_topics
                producer_pids_file="/tmp/benchmark-producer-pids.txt"
                consumer_pids_file="/tmp/benchmark-consumer-pids.txt"
                heartbeat_pid_file="/tmp/benchmark-heartbeat.pid"
                : > "$${producer_pids_file}"
                : > "$${consumer_pids_file}"
                write_cleanup_script
                start_producers
                start_consumers
                heartbeat &
                heartbeat_pid="$$!"
                printf '%s\n' "$${heartbeat_pid}" > "$${heartbeat_pid_file}"
                : > "$${ready_file}"
                log "benchmark ready"

                while true; do
                  sleep 5
                done
                EOT
              ]
              resources = {
                requests = {
                  cpu    = "500m"
                  memory = "1Gi"
                }
                limits = {
                  cpu    = "2"
                  memory = "1Gi"
                }
              }
              readinessProbe = {
                exec = {
                  command = ["/bin/sh", "-ec", "test -f /tmp/benchmark-ready"]
                }
                initialDelaySeconds = 20
                periodSeconds       = 15
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 6
              }
              livenessProbe = {
                exec = {
                  command = ["/bin/sh", "-ec", "test -f /tmp/benchmark-ready && test -f /tmp/benchmark-heartbeat"]
                }
                initialDelaySeconds = 120
                periodSeconds       = 30
                timeoutSeconds      = 1
                successThreshold    = 1
                failureThreshold    = 4
              }
              lifecycle = {
                preStop = {
                  exec = {
                    command = ["/bin/sh", "-ec", "/tmp/benchmark-cleanup.sh"]
                  }
                }
              }
            },
          ]
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
  ]
}

resource "kubernetes_manifest" "disk_headless_service" {
  for_each = local.benchmark_enabled_disk_storage_classes

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      namespace = local.benchmark_namespace_value
      labels = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
    }
    spec = {
      clusterIP = "None"
      selector = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
      ports = [
        {
          name = "fio"
          port = 8765
        },
      ]
    }
  }

  depends_on = [kubernetes_manifest.namespace]
}

resource "kubernetes_manifest" "disk_statefulset" {
  for_each = local.benchmark_enabled_disk_storage_classes

  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata = {
      name      = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      namespace = local.benchmark_namespace_value
      labels = {
        app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      }
    }
    spec = {
      replicas    = local.benchmark_disk_replicas_value
      serviceName = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
      selector = {
        matchLabels = {
          app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
        }
      }
      template = {
        metadata = {
          labels = {
            app = format("benchmark-disk-%s-%dmbs", each.key, local.benchmark_disk_rate_mbs_value)
          }
        }
        spec = {
          terminationGracePeriodSeconds = 10
          priorityClassName             = local.benchmark_priority_class_name
          containers = [
            {
              name            = "fio"
              image           = local.benchmark_fio_image_value
              imagePullPolicy = "IfNotPresent"
              command         = ["/bin/sh", "-ec"]
              args = [
                <<-EOT
                while true; do
                  fio \
                    --name="${each.key}-${local.benchmark_disk_rate_value}" \
                    --directory=/data \
                    --filename=/data/fio-benchmark.dat \
                    --rw=rw \
                    --rwmixread=50 \
                    --bs="${local.benchmark_disk_block_size_value}" \
                    --rate="${local.benchmark_disk_rate_value}" \
                    --size="${local.benchmark_disk_fio_file_size_value}" \
                    --time_based=1 \
                    --runtime="${local.benchmark_disk_runtime_value}" \
                    --ioengine=psync \
                    --direct=1 \
                    --group_reporting
                  sleep 5
                done
                EOT
              ]
              resources = {
                requests = {
                  cpu    = local.benchmark_disk_cpu_value
                  memory = local.benchmark_disk_memory_value
                }
                limits = {
                  cpu    = local.benchmark_disk_cpu_value
                  memory = local.benchmark_disk_memory_value
                }
              }
              volumeMounts = [
                {
                  name      = "data"
                  mountPath = "/data"
                },
              ]
            },
          ]
        }
      }
      volumeClaimTemplates = [
        {
          metadata = {
            name = "data"
          }
          spec = {
            accessModes      = try(each.value.access_modes, ["ReadWriteOnce"])
            storageClassName = each.value.storage_class_name
            resources = {
              requests = {
                storage = local.benchmark_disk_pvc_size_value
              }
            }
          }
        },
      ]
    }
  }

  computed_fields = [
    "spec.volumeClaimTemplates[0].metadata.creationTimestamp",
  ]

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    kubernetes_manifest.namespace,
    kubernetes_manifest.priority_class,
    kubernetes_manifest.disk_headless_service,
  ]
}

resource "kubernetes_labels" "disk_data_pvc" {
  for_each = local.benchmark_disk_pvc_labels

  api_version = "v1"
  kind        = "PersistentVolumeClaim"
  force       = true

  metadata {
    name      = each.value.name
    namespace = local.benchmark_namespace_value
  }

  labels = {
    app                            = each.value.workload
    "app.kubernetes.io/name"       = each.value.workload
    "app.kubernetes.io/instance"   = each.value.workload
    "app.kubernetes.io/component"  = "disk"
    "app.kubernetes.io/part-of"    = "benchmark"
    "app.kubernetes.io/managed-by" = "infrastructure"
    "pve-k8s-talos/section"        = "benchmark"
    "pve-k8s-talos/storage-role"   = "benchmark"
  }

  depends_on = [
    kubernetes_manifest.disk_statefulset,
  ]
}

output "benchmark_namespace" {
  value = local.benchmark_namespace_value
}

output "benchmark_cpu_workload" {
  value = local.benchmark_cpu_workload_name
}

output "benchmark_memory_workload" {
  value = local.benchmark_memory_workload_name
}

output "benchmark_disk_workloads" {
  value = [
    for name in keys(local.benchmark_enabled_disk_storage_classes) :
    format("benchmark-disk-%s-%dmbs", name, local.benchmark_disk_rate_mbs_value)
  ]
}

output "benchmark_disk_workload_summary" {
  value = join(" ", [
    for name in keys(local.benchmark_enabled_disk_storage_classes) :
    format("benchmark-disk-%s-%dmbs", name, local.benchmark_disk_rate_mbs_value)
  ])
}
