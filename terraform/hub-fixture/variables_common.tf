variable "target" {
  description = "local (Floci AZ) or azure. Selected by scripts/lib.sh, never defaulted to azure."
  type        = string
  validation {
    condition     = contains(["local", "azure"], var.target)
    error_message = "target must be local or azure."
  }
}
variable "tenant_id" { type = string }
variable "hub_subscription_id" { type = string }
variable "spoke_subscription_id" { type = string }
variable "floci_metadata_host" {
  description = "Floci ARM endpoint (local only)."
  type        = string
  default     = "localhost:4577"
  validation {
    condition     = can(regex("^(localhost|127\\.0\\.0\\.1|floci-az):[0-9]+$", var.floci_metadata_host))
    error_message = "floci_metadata_host must be a loopback/floci-az endpoint."
  }
}
variable "floci_client_id" {
  type    = string
  default = "11111111-1111-1111-1111-111111111111"
}

locals {
  is_local = var.target == "local"
  # Local: Floci custom cloud ("stack" + metadata_host), seeded dev app. Azure: public cloud,
  # credentials from the environment (OIDC / az CLI), nothing stored in the repo.
  az_environment   = local.is_local ? "stack" : "public"
  az_metadata_host = local.is_local ? var.floci_metadata_host : null
  az_client_id     = local.is_local ? var.floci_client_id : null
  az_client_secret = local.is_local ? "floci-az-dev-secret" : null
}
