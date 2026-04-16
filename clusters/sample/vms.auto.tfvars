vms = {
  "talos-cp-01" = {
    node_name  = "pve01"
    vm_id      = 1001
    type       = "controlplane"
    ip         = "192.168.1.51"
    k8s_labels = {}
  }
  "talos-cp-02" = {
    node_name  = "pve02"
    vm_id      = 1002
    type       = "controlplane"
    ip         = "192.168.1.52"
    k8s_labels = {}
  }
  "talos-cp-03" = {
    node_name  = "pve03"
    vm_id      = 1003
    type       = "controlplane"
    ip         = "192.168.1.53"
    k8s_labels = {}
  }
  "talos-wk-01" = {
    node_name  = "pve01"
    vm_id      = 1011
    type       = "worker"
    ip         = "192.168.1.61"
    k8s_labels = {}
  }
  "talos-wk-02" = {
    node_name  = "pve02"
    vm_id      = 1012
    type       = "worker"
    ip         = "192.168.1.62"
    k8s_labels = {}
  }
  "talos-wk-03" = {
    node_name  = "pve03"
    vm_id      = 1013
    type       = "worker"
    ip         = "192.168.1.63"
    k8s_labels = {}
  }
}
