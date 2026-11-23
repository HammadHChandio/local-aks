# Layered on conformance.tfvars for `make upstream-demo`. Uses ONLY upstream's own variables to switch
# off the three things Floci AZ 0.17.0 cannot emulate (verified by the defaults run):
#   storage_type=standard  -> Microsoft.Compute/disks unsupported (404) for the NFS VM data disks
#   node_pools (cas/...)   -> agentPoolProfiles[].type not returned; azurerm refuses extra pools
#   cluster_egress_type=loadBalancer -> networkProfile not returned; effective_outbound_ips lookup fails
storage_type = "none"
node_pools   = {}
