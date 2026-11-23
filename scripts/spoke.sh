#!/usr/bin/env bash
# Controlled lifecycle for the SAS spoke stack.
#   spoke.sh plan | apply | destroy | output <name>
#
# Local (Floci) apply never executes a change that plan-guard classifies as an emulator read-back
# deviation (or its cascade): those would destroy the running k3s cluster / PostgreSQL container
# because Floci does not read back ForceNew attributes. Only "real" changes are applied (-target).
# Azure apply runs the full saved plan, unchanged.
source "$(dirname "$0")/lib.sh"
load_env; floci_trust; local_secrets
KNOWN="$ROOT/terraform/tests/known-emulator-drift.json"
PLAN="$LOCAL_DIR/spoke-$TARGET.tfplan"

init() { tf spoke init -input=false >/dev/null; }

plan() {
  init
  tf spoke plan -input=false -out="$PLAN" "$@"
  tf spoke show -json "$PLAN" > "$PLAN.json"
  python3 "$ROOT/scripts/plan-guard.py" "$PLAN.json" "$KNOWN" > "$PLAN.guard.json"
  log "plan-guard: real=$(jq '.real|length' "$PLAN.guard.json") emulator-deviation=$(jq '.emulator|length' "$PLAN.guard.json") cascade=$(jq '.cascade|length' "$PLAN.guard.json")"
}

case "${1:-}" in
  plan) shift; plan "$@" ;;
  apply)
    shift; plan "$@"
    if [ "$TARGET" = azure ]; then tf spoke apply -input=false "$PLAN"; exit; fi
    n_emu=$(jq '(.emulator + .cascade)|length' "$PLAN.guard.json")
    n_real=$(jq '.real|length' "$PLAN.guard.json")
    if [ "$n_emu" = 0 ]; then
      tf spoke apply -input=false "$PLAN"
    elif [ "$n_real" = 0 ]; then
      log "converged: only documented Floci read-back deviations remain (not applied):"
      jq -r '(.emulator + .cascade)[]' "$PLAN.guard.json" | sed 's/^/    /' >&2
    else
      log "applying $n_real real change(s) only; skipping $n_emu emulator deviation(s)"
      mapfile -t targets < <(jq -r '.real[]' "$PLAN.guard.json")
      targs=(); for t in "${targets[@]}"; do targs+=("-target=$t"); done
      tf spoke apply -input=false -auto-approve "${targs[@]}"
    fi
    tf spoke output -json > "$LOCAL_DIR/spoke-outputs.json"
    ;;
  destroy)
    shift; init
    tf spoke destroy -input=false ${AUTO_APPROVE:+-auto-approve} "$@" ;;
  output) shift; tf spoke output "$@" ;;
  *) die "usage: spoke.sh plan|apply|destroy|output" ;;
esac
