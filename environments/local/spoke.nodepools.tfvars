# Plan-only locally (see spoke.tfvars). Applied as-is in Azure.
node_pools = {
  cas = {
    machine_type = "Standard_E16ds_v5", os_disk_size = 200, min_nodes = 1, max_nodes = 1, max_pods = 110
    node_taints  = ["workload.sas.com/class=cas:NoSchedule"]
    node_labels  = { "workload.sas.com/class" = "cas" }
  }
  compute = {
    machine_type = "Standard_D4ds_v5", os_disk_size = 200, min_nodes = 1, max_nodes = 1, max_pods = 110
    node_taints  = ["workload.sas.com/class=compute:NoSchedule"]
    node_labels  = { "workload.sas.com/class" = "compute", "launcher.sas.com/prepullImage" = "sas-programming-environment" }
  }
  stateless = {
    machine_type = "Standard_D4s_v5", os_disk_size = 200, min_nodes = 1, max_nodes = 2, max_pods = 110
    node_taints  = ["workload.sas.com/class=stateless:NoSchedule"]
    node_labels  = { "workload.sas.com/class" = "stateless" }
  }
  stateful = {
    machine_type = "Standard_D4s_v5", os_disk_size = 200, min_nodes = 1, max_nodes = 1, max_pods = 110
    node_taints  = ["workload.sas.com/class=stateful:NoSchedule"]
    node_labels  = { "workload.sas.com/class" = "stateful" }
  }
}
