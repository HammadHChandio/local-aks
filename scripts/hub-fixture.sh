#!/usr/bin/env bash
# Hub fixture lifecycle (LOCAL ONLY: stands in for the central platform team's own Terraform).
#   hub-fixture.sh apply | onboard-spoke | destroy | plan
source "$(dirname "$0")/lib.sh"; load_env; floci_trust
[ "$TARGET" = local ] || die "hub-fixture is never applied to Azure: the real hub belongs to the platform team"
tf hub-fixture init -input=false >/dev/null
case "${1:-apply}" in
  plan)    tf hub-fixture plan -input=false ;;
  apply)   tf hub-fixture apply -input=false -auto-approve ;;
  # Hub team's onboarding step: hub->spoke peering + DNS zone links, after the spoke VNet exists.
  onboard-spoke)
    vnet=$(jq -r '.vnet_id.value' "$LOCAL_DIR/spoke-outputs.json" 2>/dev/null) || die "spoke outputs missing (make spoke-apply)"
    [[ "$vnet" == /subscriptions/$SPOKE_SUBSCRIPTION_ID/* ]] || die "spoke vnet $vnet is not in the spoke subscription"
    printf 'spoke_vnets = {\n  sasviya = "%s"\n}\n' "$vnet" > "$LOCAL_DIR/hub-fixture.generated.tfvars"
    tf hub-fixture apply -input=false -auto-approve ;;
  destroy) tf hub-fixture destroy -input=false -auto-approve && rm -f "$LOCAL_DIR/hub-fixture.generated.tfvars" ;;
  *) die "usage: hub-fixture.sh plan|apply|onboard-spoke|destroy" ;;
esac
