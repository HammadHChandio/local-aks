locals {
  tags = merge(var.tags, {
    "owner"       = "central-platform-team"
    "lifecycle"   = "hub-managed"
    "environment" = "local-fixture"
  })
}

resource "azurerm_resource_group" "connectivity" {
  name     = "${var.hub_prefix}-connectivity-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "dns" {
  name     = "${var.hub_prefix}-dns-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "management" {
  name     = "${var.hub_prefix}-management-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.hub_prefix}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  address_space       = [var.hub_address_space]
  tags                = local.tags
}

# Azure requires these exact subnet names for Firewall / Bastion / VPN-ER gateways.
resource "azurerm_subnet" "hub" {
  for_each             = var.hub_subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [each.value]
}

# Central egress firewall. Floci stores Microsoft.Network/azureFirewalls in its generic ARM store
# only (no data plane), so locally the firewall is represented by its contract: a private IP that
# spoke UDRs point at. The resource itself is created only in a real hub (never by this fixture).
locals {
  firewall_private_ip = cidrhost(var.hub_subnets["AzureFirewallSubnet"], 4)
  dns_resolver_ip     = cidrhost(var.hub_subnets["dns-inbound"], 4)
}

resource "azurerm_private_dns_zone" "shared" {
  for_each            = toset(var.private_dns_zones)
  name                = each.value
  resource_group_name = azurerm_resource_group.dns.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each              = azurerm_private_dns_zone.shared
  name                  = "${var.hub_prefix}-vnet-link"
  resource_group_name   = azurerm_resource_group.dns.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_log_analytics_workspace" "central" {
  name                = "${var.hub_prefix}-central-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.management.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ---- Hub-team onboarding of a spoke (second apply, after the spoke VNet exists) ----------------
# Owned by the hub team: hub->spoke peering and the spoke VNet's links to the shared private DNS
# zones. The SAS spoke Terraform never creates these; it only creates its own spoke->hub peering.
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each                     = var.spoke_vnets
  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = each.value
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false # no VPN/ER gateway in the local fixture
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each = {
    for pair in setproduct(keys(var.spoke_vnets), var.private_dns_zones) :
    "${pair[0]}|${pair[1]}" => { spoke = pair[0], zone = pair[1] }
  }
  name                  = "spoke-${each.value.spoke}"
  resource_group_name   = azurerm_resource_group.dns.name
  private_dns_zone_name = azurerm_private_dns_zone.shared[each.value.zone].name
  virtual_network_id    = var.spoke_vnets[each.value.spoke]
  registration_enabled  = false
  tags                  = local.tags
}
