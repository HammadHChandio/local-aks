#!/usr/bin/env bash
# Static checks: vendored upstream intact, fmt/validate, and the safety guards refuse bad targets.
SUITE=static; source "$(dirname "$0")/../lib/result.sh"
V="$ROOT/terraform/modules/viya4-iac-azure"

check vendored-unmodified "vendored upstream modules match UPSTREAM.sha256" "$(ev vendored.txt)" \
  bash -c "cd '$V' && if command -v sha256sum >/dev/null; then sha256sum -c UPSTREAM.sha256; else shasum -a 256 -c UPSTREAM.sha256; fi"

check terraform-fmt "terraform fmt -check (own code; vendored upstream excluded)" "$(ev fmt.txt)" \
  bash -c "cd '$ROOT/terraform' && terraform fmt -check -recursive hub-fixture spoke modules/subscription-guard tests"

export TF_CLI_CONFIG_FILE="$LOCAL_DIR/terraformrc"
for s in hub-fixture spoke; do
  check "terraform-validate-$s" "terraform validate $s" "$(ev validate-$s.txt)" bash -c \
    "cd '$ROOT/terraform/$s' && TF_DATA_DIR='$LOCAL_DIR/tfdata/validate/$s' terraform init -backend=false -input=false >/dev/null && TF_DATA_DIR='$LOCAL_DIR/tfdata/validate/$s' terraform validate"
done

# --- guard rails (must REFUSE) ---------------------------------------------------------------
# refuses <expected-message-regex> <cmd...>: must fail AND say why (no passing for the wrong reason)
refuses() { local re=$1; shift; local o; if o=$("$@" 2>&1); then echo "$o"; return 1; fi; echo "$o"; grep -qE "$re" <<<"$o"; }
REALISH=3f2a9c71-5b8e-4d0a-9c6f-0e4b7a1d2c33   # random GUID shape, i.e. what a real sub id looks like
check guard-refuses-real-spoke-id "lib.sh refuses a non-fixture spoke id in local mode" "$(ev guard-real-id.txt)" \
  refuses "not a reserved local id" bash -c "cd '$ROOT' && SPOKE_SUBSCRIPTION_ID=$REALISH bash -c 'source scripts/lib.sh; set -a; . environments/local/local.env; SPOKE_SUBSCRIPTION_ID=$REALISH; guard_target'"
check guard-refuses-same-hub-spoke "lib.sh refuses hub == spoke" "$(ev guard-same.txt)" \
  refuses "must differ" bash -c "cd '$ROOT' && bash -c 'source scripts/lib.sh; set -a; . environments/local/local.env; HUB_SUBSCRIPTION_ID=\$SPOKE_SUBSCRIPTION_ID; guard_target'"
check guard-refuses-remote-endpoint "lib.sh refuses a non-loopback ARM endpoint in local mode" "$(ev guard-endpoint.txt)" \
  refuses "not a local emulator endpoint" bash -c "cd '$ROOT' && bash -c 'source scripts/lib.sh; set -a; . environments/local/local.env; FLOCI_METADATA_HOST=management.azure.com:443; guard_target'"
check guard-azure-needs-confirm "azure mode refuses without CONFIRM_AZURE" "$(ev guard-confirm.txt)" \
  refuses "requires CONFIRM_AZURE" bash -c "cd '$ROOT' && TARGET=azure HUB_SUBSCRIPTION_ID=$REALISH SPOKE_SUBSCRIPTION_ID=${REALISH/3f/4f} bash -c 'source scripts/lib.sh; guard_target'"
check guard-scrubs-ambient-arm "ARM_* credentials in the shell are scrubbed in local mode" "$(ev guard-scrub.txt)" \
  bash -c "cd '$ROOT' && ARM_CLIENT_SECRET=leak ARM_SUBSCRIPTION_ID=$REALISH bash -c 'source scripts/lib.sh; load_env; [ -z \"\${ARM_CLIENT_SECRET:-}\" ] && [ -z \"\${ARM_SUBSCRIPTION_ID:-}\" ]'"
check gitignore-protects-secrets "state, secrets and azure.env are git-ignored" "$(ev gitignore.txt)" \
  bash -c "cd '$ROOT' && git check-ignore -q .local/secrets/x && git check-ignore -q environments/azure/azure.env && git check-ignore -q terraform/spoke/x.tfstate && git check-ignore -q terraform/spoke/_backend_override.tf"
check no-real-subscription-ids "no non-fixture subscription GUIDs committed in tfvars/env" "$(ev sub-scan.txt)" \
  bash -c "cd '$ROOT' && ! git ls-files -co --exclude-standard environments terraform docker-compose.yml | grep -E '\.(tfvars|env|yml|hcl)$' | xargs grep -HnoiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | grep -viE '00000000-0000-0000-0000-|11111111-1111-1111-1111-111111111111'"
