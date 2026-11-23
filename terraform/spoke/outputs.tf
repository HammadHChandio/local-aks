output "spoke_subscription" {
  value = { id = module.spoke_guard.subscription_id, name = module.spoke_guard.display_name }
}
output "hub_subscription" {
  value = { id = module.hub_guard.subscription_id, name = module.hub_guard.display_name }
}
output "resource_group" { value = azurerm_resource_group.spoke.name }
output "vnet_id" { value = module.vnet.id }
output "subnets" { value = module.vnet.subnets }
output "aks_cluster_id" { value = module.aks.cluster_id }
output "aks_name" { value = module.aks.name }
output "kube_config" {
  value     = module.aks.kube_config
  sensitive = true
}
output "acr_login_server" {
  value = try(azurerm_container_registry.acr[0].login_server, null)
}
output "postgres" {
  value = var.postgres_server == null ? null : {
    server_name = module.flex_postgresql[0].server_name
    fqdn        = module.flex_postgresql[0].server_fqdn
    admin       = module.flex_postgresql[0].administrator_login
    server_id   = module.flex_postgresql[0].server_id
  }
}
output "rwx_filestore" {
  value = var.storage_type == "standard" ? { endpoint = module.nfs[0].private_ip_address, path = "/export" } : (
    var.storage_type == "ha" ? { endpoint = module.netapp[0].netapp_endpoint, path = module.netapp[0].netapp_path } : null
  )
}
output "egress_next_hop" { value = var.hub.firewall_private_ip }
output "required_hub_role_assignments" {
  description = "Grants the HUB team must make for this spoke (hub_rbac_mode=hub-team)."
  value       = { for k, v in local.required_hub_role_assignments : k => v }
}
output "hub_onboarding_request" {
  description = "What the hub team must configure on their side (peering, DNS links)."
  value = {
    spoke_vnet_id       = module.vnet.id
    spoke_address_space = var.vnet_address_space
    needs_hub_peering   = true
    needs_dns_links     = values(var.hub_private_dns_zones)
  }
}
