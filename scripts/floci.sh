#!/usr/bin/env bash
# Floci lifecycle. IMPORTANT: Floci keeps ARM state in memory and removes its sidecars (k3s, postgres,
# registry) when it stops. Any Floci restart therefore invalidates every local Terraform state; `up`
# detects this and refuses to continue until `make reset-local` is run.
source "$(dirname "$0")/lib.sh"; load_env
[ "$TARGET" = local ] || die "floci is local only"
case "${1:-up}" in
  up)
    docker compose -f "$ROOT/docker-compose.yml" up -d --wait floci-az floci-compat
    floci_trust
    if [ -s "$LOCAL_DIR/state/spoke.tfstate" ] && \
       ! floci "/subscriptions/$SPOKE_SUBSCRIPTION_ID/resourceGroups/sasviya-rg?api-version=2021-04-01" >/dev/null; then
      die "Floci lost its in-memory state (restart?). Local tfstate is stale: run 'make reset-local'."
    fi
    log "floci-az ready: ARM http(s)://$FLOCI_DIRECT, terraform via shim https://$FLOCI_METADATA_HOST" ;;
  down) docker compose -f "$ROOT/docker-compose.yml" down ;;
  reset)
    docker compose -f "$ROOT/docker-compose.yml" down
    docker ps -aq --filter label=io.floci.service | xargs -r docker rm -f >/dev/null || true
    rm -rf "$LOCAL_DIR/state" "$LOCAL_DIR/hub-fixture.generated.tfvars" "$LOCAL_DIR"/spoke-*.tfplan* "$LOCAL_DIR/spoke-outputs.json" "$LOCAL_DIR/kubeconfig"
    log "local state reset (provider mirror, secrets and evidence kept)" ;;
  *) die "usage: floci.sh up|down|reset" ;;
esac
