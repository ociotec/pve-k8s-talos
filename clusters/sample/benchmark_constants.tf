locals {
  benchmark_namespace    = "benchmark"
  benchmark_stress_image = "ghcr.io/colinianking/stress-ng:9df1b93b7f236617210bbad950bdd01998f381b4"
  benchmark_fio_image    = "ghcr.io/kvaps/fio:3.38"

  # Workload names include these unit sizes, for example benchmark-cpu-2vcpus.
  benchmark_cpu_vcpus    = 2
  benchmark_cpu_memory   = "256Mi"
  benchmark_cpu_replicas = 0

  # Workload names include this unit size, for example benchmark-memory-4gb.
  benchmark_memory_gb       = 4
  benchmark_memory_cpu      = "250m"
  benchmark_memory_replicas = 0
  # stress-ng allocates this percentage of the pod memory limit, leaving room
  # for process overhead so the benchmark does not self-OOM.
  benchmark_memory_stress_percent = 85

  # StatefulSet names include this rate, for example benchmark-disk-rbd-replica-10mbs.
  # Kubernetes does not expose a native PVC throughput request/limit; fio enforces
  # this rate inside the pod with --rate.
  benchmark_disk_rate_mbs      = 10
  benchmark_disk_cpu           = "50m"
  benchmark_disk_memory        = "128Mi"
  benchmark_disk_replicas      = 0
  benchmark_disk_pvc_size      = "512Mi"
  benchmark_disk_fio_file_size = "128Mi"
  benchmark_disk_block_size    = "1M"
  benchmark_disk_runtime       = "60"

  # Keep the Kafka benchmark disabled in sample clusters unless a real Redpanda
  # section is present and the profile set is intentionally enabled.
  benchmark_kafka_enabled = false

  benchmark_kafka_metadata_topics     = 50
  benchmark_kafka_metadata_partitions = 1
  benchmark_kafka_metadata_producers  = 1
  benchmark_kafka_metadata_consumers  = 1

  benchmark_kafka_balanced_topics     = 20
  benchmark_kafka_balanced_partitions = 4
  benchmark_kafka_balanced_producers  = 2
  benchmark_kafka_balanced_consumers  = 2

  benchmark_kafka_throughput_topics     = 10
  benchmark_kafka_throughput_partitions = 8
  benchmark_kafka_throughput_producers  = 4
  benchmark_kafka_throughput_consumers  = 4

  benchmark_disk_storage_classes = {
    rbd-replica = {
      enabled            = local.ceph_block_replicated.enabled
      storage_class_name = "${local.ceph_name_prefix}-rbd-replica"
      access_modes       = ["ReadWriteOnce"]
    }
    rbd-ec = {
      enabled            = local.ceph_block_ec.enabled
      storage_class_name = "${local.ceph_name_prefix}-rbd-ec"
      access_modes       = ["ReadWriteOnce"]
    }
    cephfs-replica = {
      enabled            = local.ceph_filesystem_replicated.enabled
      storage_class_name = "${local.ceph_name_prefix}-cephfs-replica"
      access_modes       = ["ReadWriteMany"]
    }
    cephfs-ec = {
      enabled            = local.ceph_filesystem_ec.enabled
      storage_class_name = "${local.ceph_name_prefix}-cephfs-ec"
      access_modes       = ["ReadWriteMany"]
    }
  }
}
