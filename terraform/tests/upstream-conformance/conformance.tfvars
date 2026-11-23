# Upstream root, upstream defaults, pointed at the SPOKE subscription in Floci.
prefix          = "sasconf"
location        = "eastus"
subscription_id = "00000000-0000-0000-0000-00000000b001"
tenant_id       = "00000000-0000-0000-0000-000000000002"
client_id       = "11111111-1111-1111-1111-111111111111"
client_secret   = "floci-az-dev-secret"

default_public_access_cidrs = ["10.99.0.0/16"] # synthetic "corporate" range
create_jump_vm              = false
storage_type                = "standard"
kubernetes_version          = "1.33"
postgres_servers = {
  default = {}
}
