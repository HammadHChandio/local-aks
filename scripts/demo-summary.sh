#!/usr/bin/env bash
# Print what the demo built, straight from the emulated Azure ARM API (not from Terraform state).
source "$(dirname "$0")/lib.sh"; load_env
ARM="http://$FLOCI_DIRECT"
c() { printf '\033[1;36m%s\033[0m\n' "$*"; }
for s in "$HUB_SUBSCRIPTION_ID:HUB (platform team)" "$SPOKE_SUBSCRIPTION_ID:SPOKE (SAS Viya)"; do
  sub=${s%%:*}; c "== Subscription $sub  ${s#*:}"
  for rg in $(curl -s "$ARM/subscriptions/$sub/resourcegroups?api-version=2021-04-01" | jq -r '.value[].name'); do
    echo "  resource group: $rg"
    curl -s "$ARM/subscriptions/$sub/resourceGroups/$rg/resources?api-version=2021-04-01" \
      | jq -r '.value[] | "      \(.type)  \(.name)"' | sort
  done
done
c "== Real containers behind the emulated services"
docker ps --filter label=io.floci.service --format '  {{.Names}}  ({{.Image}})  {{.Ports}}'
c "== AKS (k3s) via the kubeconfig produced by the upstream azure_aks module"
KUBECONFIG="$LOCAL_DIR/kubeconfig" kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
c "== Terraform: re-plan classification (real changes must be 0)"
jq -c '{real:(.real|length), emulator_gaps:(.emulator|length), cascades:(.cascade|length)}' "$LOCAL_DIR/spoke-$TARGET.tfplan.guard.json" 2>/dev/null | sed 's/^/  /'
