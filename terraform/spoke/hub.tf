# ---------------------------------------------------------------------------------------------
# Hub: READ-ONLY lookups through the hub provider alias. These fail the plan if the hub team's
# resources are missing, which is the desired behaviour (spoke depends on an existing hub).
# ---------------------------------------------------------------------------------------------
data "azurerm_virtual_network" "hub" {
  provider            = azurerm.hub
  name                = var.hub.vnet_name
  resource_group_name = var.hub.connectivity_rg
}

data "azurerm_private_dns_zone" "hub" {
  provider            = azurerm.hub
  for_each            = var.hub_private_dns_zones
  name                = each.value
  resource_group_name = var.hub.dns_rg
}

data "azurerm_log_analytics_workspace" "hub" {
  provider            = azurerm.hub
  count               = var.send_diagnostics_to_hub ? 1 : 0
  name                = var.hub.log_analytics_name
  resource_group_name = var.hub.log_analytics_rg
}

locals {
  # Hub-scope grants the SAS spoke needs. In hub-team mode they are only reported.
  required_hub_role_assignments = merge(
    var.cluster_api_mode == "private" ? {
      aks_private_dns = {
        scope                = data.azurerm_private_dns_zone.hub["aks"].id
        role_definition_name = "Private DNS Zone Contributor"
        principal_id         = azurerm_user_assigned_identity.aks.principal_id
        why                  = "AKS private cluster registers its API server A record in the hub zone"
      }
    } : {},
    {
      aks_hub_vnet_reader = {
        scope                = data.azurerm_virtual_network.hub.id
        role_definition_name = "Network Contributor"
        principal_id         = azurerm_user_assigned_identity.aks.principal_id
        why                  = "private cluster DNS zone link / peering validation against the hub VNet"
      }
    },
  )
}

# Approved-exception path only. Default (hub-team) creates nothing in the hub subscription.
resource "azurerm_role_assignment" "hub_approved" {
  provider             = azurerm.hub
  for_each             = var.hub_rbac_mode == "spoke-approved" ? local.required_hub_role_assignments : {}
  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_id
}
