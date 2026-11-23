# ---- Identity ------------------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.prefix}-aks-identity"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  tags                = local.tags
}

# Spoke-scope grants (spoke subscription only).
resource "azurerm_role_assignment" "aks_spoke_network" {
  for_each = {
    vnet        = module.vnet.id
    route_table = azurerm_route_table.egress.id
  }
  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ---- AKS (upstream module, unmodified) ----------------------------------------------------------
module "aks" {
  source = "../modules/viya4-iac-azure/modules/azure_aks"

  aks_cluster_name                         = "${var.prefix}-aks"
  aks_cluster_rg                           = azurerm_resource_group.spoke.name
  aks_cluster_dns_prefix                   = "${var.prefix}-aks"
  aks_cluster_location                     = var.location
  node_resource_group_name                 = "MC_${azurerm_resource_group.spoke.name}_${var.prefix}-aks_${var.location}"
  kubernetes_version                       = var.kubernetes_version
  aks_cluster_node_count                   = var.default_nodepool_count
  aks_cluster_node_auto_scaling            = false
  aks_cluster_min_nodes                    = null # upstream root passes null when not autoscaling;
  aks_cluster_max_nodes                    = null # azurerm rejects min/max at APPLY time otherwise
  aks_cluster_node_vm_size                 = var.default_nodepool_vm_type
  aks_vnet_subnet_id                       = module.vnet.subnets["aks"].id
  aks_private_cluster                      = var.cluster_api_mode == "private"
  aks_cluster_private_dns_zone_id          = var.cluster_api_mode == "private" ? data.azurerm_private_dns_zone.hub["aks"].id : ""
  aks_cluster_endpoint_public_access_cidrs = var.cluster_api_mode == "private" ? [] : var.cluster_endpoint_public_access_cidrs
  aks_network_plugin                       = var.aks_network_plugin
  aks_network_plugin_mode                  = var.aks_network_plugin_mode
  aks_network_policy                       = var.aks_network_policy
  aks_service_cidr                         = var.aks_service_cidr
  aks_dns_service_ip                       = var.aks_dns_service_ip
  aks_pod_cidr                             = var.aks_pod_cidr
  cluster_egress_type                      = "userDefinedRouting" # egress via hub firewall, no public LB IP
  aks_uai_id                               = azurerm_user_assigned_identity.aks.id
  aks_oms_enabled                          = false # logs go to the hub workspace via diagnostic settings
  aks_log_analytics_workspace_id           = null
  enable_workload_identity                 = var.enable_workload_identity
  rbac_aad_tenant_id                       = var.tenant_id
  aks_cluster_tags                         = local.tags

  depends_on = [
    azurerm_subnet_route_table_association.egress,
    azurerm_role_assignment.aks_spoke_network,
    azurerm_role_assignment.hub_approved,
  ]
}

module "node_pools" {
  source   = "../modules/viya4-iac-azure/modules/aks_node_pool"
  for_each = var.node_pools

  node_pool_name       = each.key
  aks_cluster_id       = module.aks.cluster_id
  vnet_subnet_id       = module.vnet.subnets["aks"].id
  machine_type         = each.value.machine_type
  os_disk_size         = each.value.os_disk_size
  auto_scaling_enabled = each.value.min_nodes != each.value.max_nodes
  node_count           = each.value.min_nodes
  min_nodes            = each.value.min_nodes == each.value.max_nodes ? null : each.value.min_nodes
  max_nodes            = each.value.min_nodes == each.value.max_nodes ? null : each.value.max_nodes
  max_pods             = each.value.max_pods
  node_taints          = each.value.node_taints
  node_labels          = each.value.node_labels
  zones                = coalesce(each.value.availability_zones, [])
  orchestrator_version = var.kubernetes_version
  # Upstream root passes null when unset; the module's own default ({}) is not usable.
  linux_os_config = each.value.linux_os_config
  tags            = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks_to_hub" {
  count                      = var.send_diagnostics_to_hub ? 1 : 0
  name                       = "${var.prefix}-aks-to-hub-law"
  target_resource_id         = module.aks.cluster_id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.hub[0].id

  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "kube-apiserver" }
  enabled_metric { category = "AllMetrics" }
}

# ---- Container registry: private endpoint, DNS in the HUB zone ----------------------------------
resource "azurerm_container_registry" "acr" {
  count                         = var.create_container_registry ? 1 : 0
  name                          = join("", regexall("[a-zA-Z0-9]+", "${var.prefix}acr"))
  resource_group_name           = azurerm_resource_group.spoke.name
  location                      = var.location
  sku                           = "Premium" # required for private endpoints
  admin_enabled                 = false
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  count               = var.create_container_registry && contains(keys(local.subnets), "privatelink") ? 1 : 0
  name                = "${var.prefix}-acr-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = module.vnet.subnets["privatelink"].id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-acr-psc"
    private_connection_resource_id = azurerm_container_registry.acr[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  # Record is written into the HUB's zone by the platform; the spoke identity needs
  # "Private DNS Zone Contributor" on it (hub-team grant, see docs/subscription-isolation.md).
  private_dns_zone_group {
    name                 = "hub-privatelink-azurecr-io"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.hub["acr"].id]
  }
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  count                = var.create_container_registry ? 1 : 0
  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ---- PostgreSQL Flexible Server (upstream module, private access) -------------------------------
module "flex_postgresql" {
  source = "../modules/viya4-iac-azure/modules/azurerm_postgresql_flex"
  count  = var.postgres_server == null ? 0 : 1

  resource_group_name    = azurerm_resource_group.spoke.name
  location               = var.location
  server_name            = lower("${var.prefix}-default")
  sku_name               = var.postgres_server.sku_name
  storage_mb             = var.postgres_server.storage_mb
  backup_retention_days  = var.postgres_server.backup_retention_days
  administrator_login    = var.postgres_server.administrator_login
  administrator_password = var.postgres_admin_password
  server_version         = var.postgres_server.server_version
  connectivity_method    = "private"
  virtual_network_id     = module.vnet.id
  delegated_subnet_id    = module.vnet.subnets["postgresql"].id
  firewall_rule_prefix   = "${var.prefix}-default-postgres-firewall-"
  firewall_rules         = []
  postgresql_configurations = [
    { name = "azure.extensions", value = "PGCRYPTO" },
    { name = "max_prepared_transactions", value = "1024" },
  ]
  tags = local.tags
}

# ---- RWX storage ----------------------------------------------------------------------------------
data "cloudinit_config" "nfs" {
  count         = var.storage_type == "standard" ? 1 : 0
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/../modules/viya4-iac-azure/files/cloud-init/nfs/cloud-config", {
      aks_cidr_block  = module.vnet.subnets["aks"].address_prefixes[0]
      misc_cidr_block = module.vnet.subnets["misc"].address_prefixes[0]
      vm_admin        = "nfsuser"
    })
  }
}

module "nfs" {
  source = "../modules/viya4-iac-azure/modules/azurerm_vm"
  count  = var.storage_type == "standard" ? 1 : 0

  name              = "${var.prefix}-nfs"
  azure_rg_name     = azurerm_resource_group.spoke.name
  azure_rg_location = var.location
  vnet_subnet_id    = module.vnet.subnets["misc"].id
  machine_type      = var.nfs_vm_machine_type
  azure_nsg_id      = azurerm_network_security_group.spoke.id
  tags              = local.tags
  vm_admin          = "nfsuser"
  ssh_public_key    = var.ssh_public_key
  cloud_init        = data.cloudinit_config.nfs[0].rendered
  create_public_ip  = false # no public IPs in the spoke
  data_disk_count   = 4
  data_disk_size    = var.nfs_raid_disk_size
}

module "netapp" {
  source = "../modules/viya4-iac-azure/modules/azurerm_netapp"
  count  = var.storage_type == "ha" ? 1 : 0

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  subnet_id           = module.vnet.subnets["netapp"].id
  vnet_id             = module.vnet.id
  network_features    = "Basic"
  service_level       = "Premium"
  size_in_tb          = 4
  protocols           = ["NFSv4.1"]
  volume_path         = "${var.prefix}-export"
  allowed_clients     = concat(module.vnet.subnets["aks"].address_prefixes, module.vnet.subnets["misc"].address_prefixes)
  tags                = local.tags
}
