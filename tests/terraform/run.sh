#!/usr/bin/env bash
# Terraform + subscription-boundary checks against the applied hub fixture and spoke (Floci).
SUITE=terraform; source "$(dirname "$0")/../lib/result.sh"
load_env; floci_trust; local_secrets
[ "$TARGET" = local ] || die "this suite asserts Floci fixture ids"
ARM="http://$FLOCI_DIRECT"; RGV="api-version=2021-04-01"
state_json() { tf "$1" show -json 2>/dev/null; }

# ---------- Subscription placement ----------------------------------------------------------------
E=$(ev placement.json)
state_json spoke | jq '[.values.root_module | .. | objects | select(has("address") and .mode=="managed" and (.type|startswith("azurerm_"))) | {address, id: (.values.id // "")}]' > "$E"
n_total=$(jq length "$E")
n_hub=$(jq --arg h "$HUB_SUBSCRIPTION_ID" '[.[]|select(.id|ascii_downcase|contains("/subscriptions/"+$h))]|length' "$E")
n_spoke=$(jq --arg s "$SPOKE_SUBSCRIPTION_ID" '[.[]|select(.id|ascii_downcase|startswith("/subscriptions/"+$s))]|length' "$E")
n_other=$(jq --arg s "$SPOKE_SUBSCRIPTION_ID" '[.[]|select((.id|ascii_downcase|startswith("/subscriptions/"+$s))|not)]' "$E" | tee "$(ev placement-outside-spoke.json)" | jq length)
if [ "$n_total" -gt 0 ] && [ "$n_hub" -eq 0 ] && [ "$n_other" -eq 0 ]; then
  pass spoke-resources-in-spoke-sub "$n_spoke/$n_total managed azurerm resources are in the spoke subscription, 0 in hub" "$E"
else
  fail spoke-resources-in-spoke-sub "total=$n_total spoke=$n_spoke hub=$n_hub outside-spoke=$n_other" "$(ev placement-outside-spoke.json)"
fi

E=$(ev rg-listing.txt)
{ for s in "$HUB_SUBSCRIPTION_ID" "$SPOKE_SUBSCRIPTION_ID" "$TRAP_SUBSCRIPTION_ID"; do
    echo "$s: $(curl -s "$ARM/subscriptions/$s/resourcegroups?$RGV" | jq -c '[.value[].name]')"; done; } > "$E"
grep -q "^$SPOKE_SUBSCRIPTION_ID: .*\"sasviya-rg\"" "$E" && ! grep -q "^$HUB_SUBSCRIPTION_ID: .*sasviya" "$E" \
  && pass sas-rg-only-in-spoke "ARM lists sasviya-rg under the spoke subscription only" "$E" \
  || fail sas-rg-only-in-spoke "sasviya-rg placement wrong" "$E"
grep -q "^$TRAP_SUBSCRIPTION_ID: \[\]" "$E" \
  && pass trap-subscription-empty "Floci default subscription holds no resource groups (nothing defaulted there)" "$E" \
  || fail trap-subscription-empty "resources leaked into the default subscription" "$E"

E=$(ev strict-subscription.txt)
code=$(curl -s -o "$E" -w '%{http_code}' -X PUT -H 'content-type: application/json' -d '{"location":"eastus"}' \
  "$ARM/subscriptions/3f2a9c71-5b8e-4d0a-9c6f-0e4b7a1d2c33/resourceGroups/should-not-exist?$RGV")
[ "$code" = 404 ] && pass unknown-subscription-refused "PUT into an unregistered subscription -> 404 SubscriptionNotFound" "$E" \
  || fail unknown-subscription-refused "unregistered subscription accepted (HTTP $code)" "$E"

# ---------- Hub untouched -----------------------------------------------------------------------
E=$(ev hub-plan.txt)
rc=0; tf hub-fixture plan -input=false -detailed-exitcode -lock=false > "$E" 2>&1 || rc=$?
[ $rc -eq 0 ] && pass hub-unchanged-after-spoke "hub fixture plan shows no changes after spoke apply" "$E" \
  || fail hub-unchanged-after-spoke "hub fixture plan exit=$rc (2=changes)" "$E"
E=$(ev hub-in-spoke-state.json)
state_json spoke | jq --arg h "$HUB_SUBSCRIPTION_ID" '[.values.root_module | .. | objects | select(has("address") and .mode=="managed") | select((.values.id // "")|ascii_downcase|contains("/subscriptions/"+$h))]' > "$E"
[ "$(jq length "$E")" = 0 ] && pass hub-not-in-spoke-lifecycle "spoke state manages 0 hub resources (destroy cannot touch hub)" "$E" \
  || fail hub-not-in-spoke-lifecycle "spoke state manages hub resources" "$E"

# ---------- Read-back, idempotency, drift ---------------------------------------------------------
KNOWN="$ROOT/terraform/tests/known-emulator-drift.json"
guard() { tf spoke show -json "$1" > "$1.json" && python3 "$ROOT/scripts/plan-guard.py" "$1.json" "$KNOWN"; }

E=$(ev refresh-only.txt)
tf spoke plan -input=false -refresh-only -lock=false -out="$LOCAL_DIR/refresh.tfplan" > "$E" 2>&1 || true
tf spoke show -json "$LOCAL_DIR/refresh.tfplan" | jq '[(.resource_drift // [])[] | .address]' > "$(ev read-back-drift.json)"
n_res=$(tf spoke state list | wc -l)
pass read-back "$n_res state objects re-read from Floci ARM ($(jq length "$(ev read-back-drift.json)") reported drifted; classified below)" "$(ev read-back-drift.json)"

E=$(ev idempotency.json)
tf spoke plan -input=false -lock=false -out="$LOCAL_DIR/idem.tfplan" > "$(ev idempotency-plan.txt)" 2>&1
guard "$LOCAL_DIR/idem.tfplan" > "$E"
if [ "$(jq '.real|length' "$E")" = 0 ]; then
  pass idempotent "re-plan has 0 real changes ($(jq '.emulator|length' "$E") emulator deviations, $(jq '.cascade|length' "$E") cascades)" "$E"
else
  fail idempotent "re-plan has real changes: $(jq -c .real "$E")" "$E"
fi
for addr in $(jq -r '.emulator[]' "$E"); do
  blocked "idempotency-emulator:$addr" "$(jq -r --arg a "$addr" '.deviations[]|select(.address==$a)|.reason' "$KNOWN") [paths: $(jq -r --arg a "$addr" '.details[$a].paths|join(",")' "$E")]" "$E"
done

# ---------- Cross-subscription references ---------------------------------------------------------
E=$(ev cross-sub-refs.json)
# Floci does not read back the AKS private DNS zone; assert the value Terraform SENDS (planned values).
aks_sent=$(jq -c '[.planned_values.root_module | .. | objects | select(.type?=="azurerm_kubernetes_cluster") | .values.private_dns_zone_id][0]' "$LOCAL_DIR/idem.tfplan.json")
state_json spoke | jq --arg h "$HUB_SUBSCRIPTION_ID" --argjson aks_sent "$aks_sent" '{
  peering_remote: ([.. | objects | select(.type=="azurerm_virtual_network_peering") | .values.remote_virtual_network_id][0]),
  pe_dns_zone:    ([.. | objects | select(.type=="azurerm_private_endpoint") | .values.private_dns_zone_group[0].private_dns_zone_ids[0]][0]),
  diag_workspace: ([.. | objects | select(.type=="azurerm_monitor_diagnostic_setting") | .values.log_analytics_workspace_id][0]),
  aks_private_dns:$aks_sent,
  route_next_hop: ([.. | objects | select(.type=="azurerm_route_table") | .values.route[0].next_hop_in_ip_address][0]),
  hub_data_sources: ([.. | objects | select(.mode=="data" and .provider_name=="registry.terraform.io/hashicorp/azurerm") | select((.values.id//"")|ascii_downcase|contains("/subscriptions/"+$h)) | .address])
}' > "$E"
if jq -e --arg h "$HUB_SUBSCRIPTION_ID" '[.peering_remote,.pe_dns_zone,.diag_workspace,.aks_private_dns] | all(. != null and (ascii_downcase|contains("/subscriptions/"+$h)))' "$E" >/dev/null \
   && jq -e '.route_next_hop=="10.0.1.4" and (.hub_data_sources|length) >= 3' "$E" >/dev/null; then
  pass cross-sub-references "peering, PE DNS zone, diag workspace, AKS private zone resolve to hub; UDR -> hub firewall" "$E"
else fail cross-sub-references "a cross-subscription reference did not resolve to the hub" "$E"; fi

# Drift: change the NSG's tags out-of-band through ARM, expect Terraform to detect and repair it.
E=$(ev drift.txt)
NSG="$ARM/subscriptions/$SPOKE_SUBSCRIPTION_ID/resourceGroups/sasviya-rg/providers/Microsoft.Network/networkSecurityGroups/sasviya-nsg?api-version=2024-05-01"
{ curl -s "$NSG" | jq '.tags.drift="out-of-band"' | curl -s -X PUT -H 'content-type: application/json' -d @- "$NSG" | jq -c .tags
  rc=0; tf spoke plan -input=false -detailed-exitcode -lock=false -target=azurerm_network_security_group.spoke || rc=$?; echo "drift-plan-exit=$rc"
  rc=0; tf spoke apply -input=false -auto-approve -lock=false -target=azurerm_network_security_group.spoke >/dev/null 2>&1 || rc=$?; echo "repair-exit=$rc"
  rc=0; tf spoke plan -input=false -detailed-exitcode -lock=false -target=azurerm_network_security_group.spoke || rc=$?; echo "post-repair-plan-exit=$rc"; } > "$E" 2>&1
grep -q 'drift-plan-exit=2' "$E" && grep -q 'repair-exit=0' "$E" && grep -q 'post-repair-plan-exit=0' "$E" \
  && pass drift-detect-repair "out-of-band tag change detected (exit 2), repaired, converged (exit 0)" "$E" \
  || fail drift-detect-repair "drift cycle incomplete" "$E"

# ---------- Guard: CIDR overlap refused at plan time -------------------------------------------------
E=$(ev overlap-refused.txt)
tf spoke plan -input=false -lock=false -refresh=false -var aks_service_cidr=10.0.0.0/16 -var aks_dns_service_ip=10.0.0.10 > "$E" 2>&1 || true
grep -qE 'Overlapping address spaces: .*(hub-0<->aks_service|aks_service<->hub-0)' "$E" \
  && pass overlap-refused "upstream default service CIDR 10.0.0.0/16 collides with hub -> plan refused" "$E" \
  || fail overlap-refused "overlap not detected" "$E"
