# ---------------- Naming / placement ----------------
variable "prefix" {
  description = "SAS deployment prefix (upstream naming: <prefix>-rg, <prefix>-aks, ...)."
  type        = string
  default     = "sasviya"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.prefix))
    error_message = "prefix: 3-16 chars, lowercase alphanumerics/hyphen, starting with a letter."
  }
}
variable "location" {
  type    = string
  default = "eastus"
}
variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------- Hub interface contract (inputs, never hub state) ----------------
variable "hub" {
  description = "Names of centrally managed hub resources the spoke consumes (read via data sources)."
  type = object({
    connectivity_rg     = string
    vnet_name           = string
    dns_rg              = string
    firewall_private_ip = string       # next hop for 0.0.0.0/0
    dns_servers         = list(string) # hub DNS resolver / firewall DNS proxy
    log_analytics_rg    = optional(string)
    log_analytics_name  = optional(string)
  })
}
variable "hub_private_dns_zones" {
  description = "Logical name => hub private DNS zone name."
  type        = map(string)
  default = {
    aks = "privatelink.eastus.azmk8s.io"
    acr = "privatelink.azurecr.io"
  }
}
variable "hub_rbac_mode" {
  description = <<-EOT
    hub-team       : spoke writes NOTHING in the hub. Required hub-scope role assignments are output
                     (required_hub_role_assignments) for the central team to grant.
    spoke-approved : spoke creates those role assignments itself through azurerm.hub. Use only with an
                     approved exception; the hub SP/identity must hold User Access Administrator there.
  EOT
  type        = string
  default     = "hub-team"
  validation {
    condition     = contains(["hub-team", "spoke-approved"], var.hub_rbac_mode)
    error_message = "hub_rbac_mode must be hub-team or spoke-approved."
  }
}
variable "create_spoke_to_hub_peering" {
  description = "Create the spoke-side peering (spoke subscription). The hub-side peering is always the hub team's."
  type        = bool
  default     = true
}
variable "use_remote_gateways" {
  description = "Use the hub's VPN/ExpressRoute gateway (requires hub-side allow_gateway_transit)."
  type        = bool
  default     = false
}

# ---------------- Spoke network ----------------
variable "vnet_address_space" {
  type    = string
  default = "10.20.0.0/16"
}
variable "subnets" {
  description = "Spoke subnets (upstream viya4-iac-azure schema). Keys aks/misc are required; postgresql is required for private PG; privatelink hosts private endpoints."
  type = map(object({
    prefixes                                      = list(string)
    service_endpoints                             = list(string)
    private_endpoint_network_policies             = string
    private_link_service_network_policies_enabled = bool
    service_delegations = map(object({
      name    = string
      actions = list(string)
    }))
  }))
}
variable "aks_service_cidr" {
  type    = string
  default = "172.20.0.0/16"
}
variable "aks_dns_service_ip" {
  type    = string
  default = "172.20.0.10"
}
variable "aks_pod_cidr" {
  type    = string
  default = "172.21.0.0/16"
}
variable "aks_network_plugin" {
  type    = string
  default = "azure"
}
variable "aks_network_plugin_mode" {
  type    = string
  default = "overlay"
}
variable "aks_network_policy" {
  type    = string
  default = "azure"
}
variable "admin_source_cidrs" {
  description = "Approved inbound sources (e.g. hub Bastion / corporate ranges via hub) allowed to reach the spoke."
  type        = list(string)
  default     = []
}

# ---------------- AKS ----------------
variable "kubernetes_version" {
  type    = string
  default = "1.33"
}
variable "cluster_api_mode" {
  description = "private (enterprise default) or public."
  type        = string
  default     = "private"
  validation {
    condition     = contains(["private", "public"], var.cluster_api_mode)
    error_message = "cluster_api_mode must be private or public."
  }
}
variable "cluster_endpoint_public_access_cidrs" {
  type    = list(string)
  default = []
}
variable "default_nodepool_vm_type" {
  type    = string
  default = "Standard_E8s_v5"
}
variable "default_nodepool_count" {
  type    = number
  default = 2
}
variable "enable_workload_identity" {
  type    = bool
  default = true
}
variable "node_pools" {
  description = "Upstream node_pools schema (cas, compute, stateless, stateful ...)."
  type = map(object({
    machine_type       = string
    os_disk_size       = number
    min_nodes          = number
    max_nodes          = number
    max_pods           = number
    node_taints        = list(string)
    node_labels        = map(string)
    availability_zones = optional(list(string))
    linux_os_config = optional(object({
      sysctl_config = optional(object({ vm_max_map_count = optional(number) }))
    }))
  }))
}

# ---------------- Data services ----------------
variable "create_container_registry" {
  type    = bool
  default = true
}
variable "postgres_server" {
  description = "Single external PostgreSQL Flexible Server for SAS Infrastructure Data Server (null to use internal Crunchy PG)."
  type = object({
    sku_name              = optional(string, "GP_Standard_D4s_v3")
    storage_mb            = optional(number, 131072)
    server_version        = optional(string, "16")
    backup_retention_days = optional(number, 7)
    administrator_login   = optional(string, "pgadmin")
  })
  default = {}
}
variable "postgres_admin_password" {
  description = "Supplied via TF_VAR_postgres_admin_password (generated into .local/secrets locally; Key Vault/pipeline secret in Azure)."
  type        = string
  sensitive   = true
}
variable "storage_type" {
  description = "standard = upstream NFS VM, ha = upstream Azure NetApp Files, none = bring your own RWX storage."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "ha", "none"], var.storage_type)
    error_message = "storage_type must be standard, ha or none."
  }
}
variable "nfs_vm_machine_type" {
  type    = string
  default = "Standard_D4s_v5"
}
variable "nfs_raid_disk_size" {
  type    = number
  default = 256
}
variable "ssh_public_key" {
  description = "Public key for the NFS VM admin user. Generated locally by scripts if empty."
  type        = string
  default     = ""
}
variable "send_diagnostics_to_hub" {
  description = "Send AKS control-plane logs to the hub's central Log Analytics workspace."
  type        = bool
  default     = true
}
