resources = {
  # These are example values, update them to match your environment
  "controlplane" = {
    vcpus      = 2
    memory     = 2048
    k8s_node   = "controlplane"
    k8s_labels = {}
    disks = [
      { size = 32 }, # First disk is used as the root disk
    ]
  }
  "worker" = {
    vcpus      = 4
    memory     = 8192
    k8s_node   = "worker"
    k8s_labels = {}
    disks = [
      { size = 32 }, # First disk is used as the root disk
      { size = 128 },
    ]
  }
  "worker-kafka" = {
    vcpus      = 4
    memory     = 8192
    k8s_node   = "worker"
    k8s_labels = { "kafka" = "yes" }
    disks = [
      { size = 32 }, # First disk is used as the root disk
      { size = 128 },
      { size = 64, mount = "/var/lib/kafka" },
    ]
  }
}
