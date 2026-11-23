terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "4.64.0" # same pin as upstream viya4-iac-azure
      configuration_aliases = []
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
  backend "local" {}
}

# DEFAULT provider == SPOKE subscription. Every resource in this stack (and in the vendored
# upstream modules, which inherit the default provider) is created in the spoke.
provider "azurerm" {
  features {}
  environment                     = local.az_environment
  metadata_host                   = local.az_metadata_host
  subscription_id                 = var.spoke_subscription_id
  tenant_id                       = var.tenant_id
  client_id                       = local.az_client_id
  client_secret                   = local.az_client_secret
  use_cli                         = !local.is_local
  resource_provider_registrations = local.is_local ? "none" : "core"
}

# HUB subscription: READ-ONLY by convention and by test (tests/terraform/test_hub_untouched.sh
# fails if any managed resource in spoke state lives in the hub subscription, except the
# explicitly approved items listed in local.approved_hub_writes).
provider "azurerm" {
  alias = "hub"
  features {}
  environment                     = local.az_environment
  metadata_host                   = local.az_metadata_host
  subscription_id                 = var.hub_subscription_id
  tenant_id                       = var.tenant_id
  client_id                       = local.az_client_id
  client_secret                   = local.az_client_secret
  use_cli                         = !local.is_local
  resource_provider_registrations = "none" # never register providers in someone else's subscription
}

module "spoke_guard" {
  source                   = "../modules/subscription-guard"
  role                     = "spoke"
  expected_subscription_id = var.spoke_subscription_id
  expected_tenant_id       = var.tenant_id
  target                   = var.target
}

module "hub_guard" {
  source                   = "../modules/subscription-guard"
  providers                = { azurerm = azurerm.hub }
  role                     = "hub"
  expected_subscription_id = var.hub_subscription_id
  expected_tenant_id       = var.tenant_id
  target                   = var.target
}
