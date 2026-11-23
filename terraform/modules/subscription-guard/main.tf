# Fails the plan if the provider passed in is not pointed at the expected subscription,
# or if a local run is configured with anything other than reserved fixture ids.
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

variable "role" {
  description = "hub | spoke (for messages only)"
  type        = string
}
variable "expected_subscription_id" { type = string }
variable "expected_tenant_id" { type = string }
variable "target" { type = string }

data "azurerm_subscription" "this" {}

locals {
  local_fixture_re = "^00000000-0000-0000-0000-[0-9a-f]{12}$"
}

resource "terraform_data" "assert" {
  input = data.azurerm_subscription.this.subscription_id

  lifecycle {
    precondition {
      condition     = lower(data.azurerm_subscription.this.subscription_id) == lower(var.expected_subscription_id)
      error_message = "${var.role} provider resolved subscription ${data.azurerm_subscription.this.subscription_id}, expected ${var.expected_subscription_id}."
    }
    precondition {
      condition     = lower(data.azurerm_subscription.this.tenant_id) == lower(var.expected_tenant_id)
      error_message = "${var.role} subscription belongs to tenant ${data.azurerm_subscription.this.tenant_id}, expected ${var.expected_tenant_id}."
    }
    precondition {
      condition     = var.target != "local" || can(regex(local.local_fixture_re, lower(var.expected_subscription_id)))
      error_message = "Local target may only use reserved fixture subscription ids (00000000-0000-0000-0000-…)."
    }
    precondition {
      condition     = var.target != "azure" || !can(regex(local.local_fixture_re, lower(var.expected_subscription_id)))
      error_message = "Azure target configured with a local fixture subscription id."
    }
  }
}

output "subscription_id" { value = data.azurerm_subscription.this.subscription_id }
output "display_name" { value = data.azurerm_subscription.this.display_name }
