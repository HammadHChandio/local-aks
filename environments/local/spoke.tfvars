prefix   = "sasviya"
location = "eastus"
tags = {
  environment = "local-floci"
  cost_center = "sas-platform"
  data_class  = "synthetic"
}

# Interface contract published by the hub team (see terraform/hub-fixture outputs.hub_contract)
hub = {
  connectivity_rg     = "hub-connectivity-rg"
  vnet_name           = "hub-vnet"
  dns_rg              = "hub-dns-rg"
  firewall_private_ip = "10.0.1.4"
  dns_servers         = ["10.0.4.4"]
  log_analytics_rg    = "hub-management-rg"
  log_analytics_name  = "hub-central-law"
}
hub_rbac_mode = "hub-team" # spoke writes nothing to the hub

vnet_address_space = "10.20.0.0/16"
subnets = {
  aks = {
    prefixes                                      = ["10.20.0.0/22"]
    service_endpoints                             = []
    private_endpoint_network_policies             = "Enabled"
    private_link_service_network_policies_enabled = false
    service_delegations                           = {}
  }
  misc = {
    prefixes                                      = ["10.20.4.0/24"]
    service_endpoints                             = []
    private_endpoint_network_policies             = "Enabled"
    private_link_service_network_policies_enabled = false
    service_delegations                           = {}
  }
  postgresql = {
    prefixes                                      = ["10.20.5.0/24"]
    service_endpoints                             = []
    private_endpoint_network_policies             = "Enabled"
    private_link_service_network_policies_enabled = false
    service_delegations = {
      flexpostgres = {
        name    = "Microsoft.DBforPostgreSQL/flexibleServers"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
  privatelink = {
    prefixes                                      = ["10.20.6.0/24"]
    service_endpoints                             = []
    private_endpoint_network_policies             = "Enabled"
    private_link_service_network_policies_enabled = false
    service_delegations                           = {}
  }
}
aks_service_cidr   = "172.20.0.0/16"
aks_dns_service_ip = "172.20.0.10"
aks_pod_cidr       = "172.21.0.0/16"

cluster_api_mode = "private"
# Floci runs whatever k3s image it is configured with; this value is ARM state only locally.
kubernetes_version = "1.33"

# SAS node pools (cas/compute/stateless/stateful) live in spoke.nodepools.tfvars. Floci 0.17.0 does not
# report agentPoolProfiles[].type, so azurerm refuses extra pools at APPLY ("multiple node pools are only
# supported when the Default Node Pool uses a VMScaleSet"). They are plan-verified only, locally.
node_pools = {}

postgres_server = { server_version = "16" }
# Floci has no Microsoft.Compute/disks (404), so the upstream NFS VM (4 data disks) cannot be
# emulated. Locally, RWX storage is a real in-cluster NFS server (kubernetes/storage). Azure uses "standard".
storage_type = "none"
