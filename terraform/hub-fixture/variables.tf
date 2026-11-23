variable "hub_prefix" {
  type    = string
  default = "hub"
}
variable "location" {
  type    = string
  default = "eastus"
}
variable "hub_address_space" {
  type    = string
  default = "10.0.0.0/16"
}
variable "hub_subnets" {
  type = map(string)
  default = {
    AzureFirewallSubnet = "10.0.1.0/26"
    AzureBastionSubnet  = "10.0.2.0/26"
    GatewaySubnet       = "10.0.3.0/27"
    dns-inbound         = "10.0.4.0/28"
  }
}
variable "private_dns_zones" {
  description = "Centrally owned private DNS zones that spokes consume."
  type        = list(string)
  default = [
    "privatelink.eastus.azmk8s.io",
    "privatelink.postgres.database.azure.com",
    "privatelink.azurecr.io",
    "privatelink.file.core.windows.net",
    "privatelink.blob.core.windows.net",
  ]
}
variable "spoke_vnets" {
  description = "Spoke VNets onboarded by the hub team: name => VNet resource id (any subscription)."
  type        = map(string)
  default     = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}
