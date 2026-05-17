locals {
  redpanda_namespace               = "kafka"
  redpanda_resource_name           = "redpanda"
  redpanda_cluster_id              = "GCS"
  redpanda_broker_k8s_annotation   = "kafka-node"
  redpanda_broker_data_host_path   = "/var/lib/kafka"
  redpanda_storage_class_name      = "redpanda-local"
  redpanda_console_hostname        = "redpanda-console.${local.domain}"
  redpanda_console_tls_secret_name = "redpanda-console-tls"
  redpanda_image                   = "docker.redpanda.com/redpandadata/redpanda:v26.1.6"
  redpanda_console_image           = "docker.redpanda.com/redpandadata/console:v3.7.2"

  # Redpanda cluster-wide settings. Keys must match official Redpanda cluster
  # properties. Numeric values are passed through unchanged; strings may use
  # helper units: time-like keys accept s/m/h/d, byte-like keys accept k/m/g,
  # and percent/percentage keys accept either 80 or "80%".
  # https://docs.redpanda.com/current/reference/properties/cluster-properties/
  redpanda_cluster_config = {
    # Prevent accidental topic creation by clients that produce to a typoed topic.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#auto_create_topics_enabled
    auto_create_topics_enabled = false

    # Use three replicas for newly-created topics on the three-broker cluster.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#default_topic_replication
    default_topic_replications = 3

    # Reject newly-created topics that request fewer than three replicas.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#minimum_topic_replication
    minimum_topic_replications = 3

    # Keep internal topics replicated across all three brokers.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#internal_topic_replication_factor
    internal_topic_replication_factor = 3

    # Create new topics with enough partitions for moderate parallelism by default.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#default_topic_partitions
    default_topic_partitions = 3

    # Retain topic data for 1 hour unless a topic overrides retention.ms.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#log_retention_ms
    log_retention_ms = "1h"

    # Roll segments every hour so time-based retention can reclaim data predictably.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#log_segment_ms
    log_segment_ms = "1h"

    # Use 4 MiB default segment files for topics without segment.bytes.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#log_segment_size
    log_segment_size = "4m"

    # Export consumer, topic, committed-offset, and lag metrics for Grafana dashboards.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#enable_consumer_group_metrics
    enable_consumer_group_metrics = ["group", "partition", "consumer_lag"]

    # Collect consumer lag once per minute to balance freshness and broker overhead.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#consumer_group_lag_collection_interval_sec
    consumer_group_lag_collection_interval_sec = "60s"

    # Disable Redpanda Data usage reporting; this does not disable Prometheus metrics.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#enable_metrics_reporter
    enable_metrics_reporter = false

    # Stop accepting producer writes before broker disks run critically low.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#storage_min_free_bytes
    storage_min_free_bytes = "1g"

    # Rebalance partitions automatically when brokers are added.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#partition_autobalancing_mode
    partition_autobalancing_mode = "node_add"

    # Keep community clusters on the non-Enterprise core balancing behavior.
    # https://docs.redpanda.com/current/reference/properties/cluster-properties/#core_balancing_continuous
    core_balancing_continuous = false
  }

  redpanda_console_auth_keycloak_realm = "company"
  redpanda_console_auth_allowed_groups = ["k8s-admins"]
  redpanda_console_auth_ca_secret_name = "redpanda-console-oauth-ca"

  redpanda_console_oauth2_proxy_image_tag         = "v7.15.2"
  redpanda_console_oauth2_proxy_cookie_name       = "_redpanda_console_oauth2_proxy"
  redpanda_console_oauth2_proxy_cpu_request       = "50m"
  redpanda_console_oauth2_proxy_cpu_limit         = "200m"
  redpanda_console_oauth2_proxy_mem_request       = "128Mi"
  redpanda_console_oauth2_proxy_mem_limit         = "128Mi"
  redpanda_console_oauth2_proxy_trusted_proxy_ips = []

  redpanda_broker_cpu_request = "2"
  redpanda_broker_cpu_limit   = "3"
  redpanda_broker_mem_request = "4Gi"
  redpanda_broker_mem_limit   = "4Gi"

  # Keep Redpanda internal memory below the Kubernetes memory limit so the process
  # has headroom for non-Redpanda allocations inside the container.
  redpanda_enable_smp_memory_flags = true
  redpanda_smp                     = 2
  redpanda_memory                  = "2Gi"

  redpanda_config_renderer_cpu_request = "50m"
  redpanda_config_renderer_cpu_limit   = "200m"
  redpanda_config_renderer_mem_request = "64Mi"
  redpanda_config_renderer_mem_limit   = "64Mi"

  redpanda_console_cpu_request = "100m"
  redpanda_console_cpu_limit   = "500m"
  redpanda_console_mem_request = "256Mi"
  redpanda_console_mem_limit   = "256Mi"
}
