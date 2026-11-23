terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.64.0" # same pin as upstream viya4-iac-azure
    }
  }
  backend "local" {}
}

# The hub fixture has exactly ONE provider: the hub subscription. It stands in for the central
# platform team's own Terraform. The SAS spoke never applies this stack.
provider "azurerm" {
  features {}
  environment                     = local.az_environment
  metadata_host                   = local.az_metadata_host
  subscription_id                 = var.hub_subscription_id
  tenant_id                       = var.tenant_id
  client_id                       = local.az_client_id
  client_secret                   = local.az_client_secret
  use_cli                         = !local.is_local
  resource_provider_registrations = local.is_local ? "none" : "core"
}

module "guard" {
  source                   = "../modules/subscription-guard"
  role                     = "hub"
  expected_subscription_id = var.hub_subscription_id
  expected_tenant_id       = var.tenant_id
  target                   = var.target
}

# This stack is a LOCAL FIXTURE. It must never be applied against a real hub.
resource "terraform_data" "local_only" {
  lifecycle {
    precondition {
      condition     = local.is_local
      error_message = "hub-fixture is a local stand-in for centrally managed infrastructure; it is never applied to Azure."
    }
  }
}
