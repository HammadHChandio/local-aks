# Terraform override file: merged INTO upstream's own `provider "azurerm"` block at load time.
# This is the only change applied to the upstream root module; no upstream file is edited.
provider "azurerm" {
  environment                     = "stack"
  metadata_host                   = "localhost:4578" # compat shim: AKS user-credential name fix
  use_cli                         = false
  resource_provider_registrations = "none"
}
