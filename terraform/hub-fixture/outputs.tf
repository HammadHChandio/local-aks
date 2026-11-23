# The interface contract handed to spoke teams. Spokes read these as INPUTS + data sources;
# they never read this stack's state.
output "hub_contract" {
  value = {
    subscription_id         = var.hub_subscription_id
    connectivity_rg         = azurerm_resource_group.connectivity.name
    dns_rg                  = azurerm_resource_group.dns.name
    hub_vnet_name           = azurerm_virtual_network.hub.name
    hub_vnet_id             = azurerm_virtual_network.hub.id
    hub_address_space       = var.hub_address_space
    firewall_private_ip     = local.firewall_private_ip
    dns_servers             = [local.dns_resolver_ip]
    private_dns_zone_ids    = { for k, z in azurerm_private_dns_zone.shared : k => z.id }
    log_analytics_workspace = azurerm_log_analytics_workspace.central.id
  }
}
