locals {
  tags = merge(var.tags, {
    "workload"    = "sas-viya"
    "lifecycle"   = "spoke-managed"
    "hub_vnet_id" = data.azurerm_virtual_network.hub.id
  })

  # Upstream behaviour: the netapp subnet exists only for storage_type=ha.
  subnets = { for k, v in var.subnets : k => v if !(k == "netapp" && var.storage_type != "ha") }

  # ---- CIDR non-overlap (hub, spoke, AKS service, AKS pod) -------------------------------------
  cidrs = merge(
    { for i, c in data.azurerm_virtual_network.hub.address_space : "hub-${i}" => c },
    { spoke = var.vnet_address_space, aks_service = var.aks_service_cidr },
    var.aks_network_plugin_mode == "overlay" || var.aks_network_plugin == "kubenet" ? { aks_pod = var.aks_pod_cidr } : {},
  )
  ranges = { for k, c in local.cidrs : k => {
    start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
    end   = sum([for i, o in split(".", cidrhost(c, pow(2, 32 - tonumber(split("/", c)[1])) - 1)) : tonumber(o) * pow(256, 3 - i)])
  } }
  range_keys = keys(local.ranges)
  overlaps = flatten([for i, a in local.range_keys : [for j, b in local.range_keys : "${a}<->${b}"
  if i < j && local.ranges[a].start <= local.ranges[b].end && local.ranges[b].start <= local.ranges[a].end]])
  subnet_outside_spoke = [for k, s in local.subnets : k
  if !alltrue([for p in s.prefixes : cidrsubnet(p, 0, 0) == p && local.ranges.spoke.start <= sum([for i, o in split(".", cidrhost(p, 0)) : tonumber(o) * pow(256, 3 - i)]) && sum([for i, o in split(".", cidrhost(p, pow(2, 32 - tonumber(split("/", p)[1])) - 1)) : tonumber(o) * pow(256, 3 - i)]) <= local.ranges.spoke.end])]
}

resource "terraform_data" "network_contract" {
  input = local.cidrs
  lifecycle {
    precondition {
      condition     = length(local.overlaps) == 0
      error_message = "Overlapping address spaces: ${join(", ", local.overlaps)}"
    }
    precondition {
      condition     = length(local.subnet_outside_spoke) == 0
      error_message = "Subnets outside the spoke VNet: ${join(", ", local.subnet_outside_spoke)}"
    }
    precondition {
      condition     = alltrue([for k in ["aks", "misc"] : contains(keys(local.subnets), k)])
      error_message = "subnets must define aks and misc (upstream contract)."
    }
  }
}

resource "azurerm_resource_group" "spoke" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

# ---- Upstream VNet module (unmodified), DNS pointed at the hub resolver -----------------------
module "vnet" {
  source = "../modules/viya4-iac-azure/modules/azurerm_vnet"

  prefix               = var.prefix
  resource_group_name  = azurerm_resource_group.spoke.name
  location             = var.location
  subnets              = local.subnets
  address_space        = [var.vnet_address_space]
  dns_servers          = var.hub.dns_servers
  aks_uai_principal_id = azurerm_user_assigned_identity.aks.principal_id
  add_uai_permissions  = false
  tags                 = local.tags
  depends_on           = [terraform_data.network_contract]
}

# ---- Default-deny NSG --------------------------------------------------------------------------
resource "azurerm_network_security_group" "spoke" {
  name                = "${var.prefix}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "allow_vnet_inbound" {
  name                        = "allow-intra-spoke"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.vnet_address_space
  destination_address_prefix  = var.vnet_address_space
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.spoke.name
}

resource "azurerm_network_security_rule" "allow_approved_inbound" {
  count                       = length(var.admin_source_cidrs) > 0 ? 1 : 0
  name                        = "allow-approved-https-from-hub"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["443"]
  source_address_prefixes     = var.admin_source_cidrs
  destination_address_prefix  = var.vnet_address_space
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.spoke.name
}

resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "deny-all-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.spoke.name
}

resource "azurerm_subnet_network_security_group_association" "spoke" {
  # delegated PG subnet keeps its own (service-managed) policy
  for_each                  = { for k, v in module.vnet.subnets : k => v if k != "postgresql" && k != "netapp" }
  subnet_id                 = each.value.id
  network_security_group_id = azurerm_network_security_group.spoke.id
}

# ---- Forced egress through the hub firewall (AKS outboundType=userDefinedRouting) ------------
resource "azurerm_route_table" "egress" {
  name                          = "${var.prefix}-rt-egress-hub"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.spoke.name
  bgp_route_propagation_enabled = false
  tags                          = local.tags

  route {
    name                   = "default-via-hub-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.hub.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "egress" {
  for_each       = { for k, v in module.vnet.subnets : k => v if contains(["aks", "misc"], k) }
  subnet_id      = each.value.id
  route_table_id = azurerm_route_table.egress.id
}

# ---- Spoke side of hub connectivity (hub side belongs to the hub team) -------------------------
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count                        = var.create_spoke_to_hub_peering ? 1 : 0
  name                         = "peer-${var.prefix}-to-hub"
  resource_group_name          = azurerm_resource_group.spoke.name
  virtual_network_name         = module.vnet.name
  remote_virtual_network_id    = data.azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = var.use_remote_gateways

  # module.vnet.name is computed from inputs, so it carries no implicit dependency on the VNet.
  # Floci accepted a peering under a not-yet-created VNet; real ARM returns ParentResourceNotFound.
  depends_on = [module.vnet]
}
