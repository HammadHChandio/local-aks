#!/usr/bin/env bash
# Upstream conformance: unmodified sassoftware/viya4-iac-azure ROOT module @ pinned commit,
# against the Floci spoke subscription. Records each lifecycle step as PASS/FAIL with logs.
#   usage: run.sh [defaults|floci]
#     defaults : upstream defaults (conformance report: shows exactly where Floci falls short)
#     floci    : defaults + floci-profile.tfvars (upstream variables only) -> full apply/destroy demo
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../../scripts/lib.sh"
load_env; floci_trust; local_secrets
[ "$TARGET" = local ] || die "conformance runs against Floci only"

PROFILE="${1:-floci}"
case "$PROFILE" in defaults) EGRESS=loadBalancer; EXTRA=();; floci) EGRESS=userDefinedRouting; EXTRA=(-var-file="$HERE/floci-profile.tfvars");; *) die "profile: defaults|floci";; esac
REF=$(awk '/Commit:/{print $3}' "$ROOT/terraform/modules/viya4-iac-azure/VENDORED.md")
WORK="$LOCAL_DIR/upstream-conformance-$PROFILE"
OUT="$LOCAL_DIR/evidence/upstream-conformance-$PROFILE"
mkdir -p "$OUT"
if [ ! -d "$WORK/.git" ]; then
  git clone -q https://github.com/sassoftware/viya4-iac-azure.git "$WORK"
fi
git -C "$WORK" fetch -q --depth 1 origin "$REF" 2>/dev/null || true
git -C "$WORK" checkout -q "$REF"
git -C "$WORK" status --porcelain | grep -v '^??' && die "upstream checkout is modified"
cp "$HERE/floci_override.tf" "$WORK/floci_override.tf"

export TF_CLI_CONFIG_FILE="$LOCAL_DIR/terraformrc" TF_DATA_DIR="$WORK/.terraform" TF_IN_AUTOMATION=1
VARS=(-var-file="$HERE/conformance.tfvars" -var="ssh_public_key=$LOCAL_DIR/secrets/id_ed25519.pub" -var="cluster_egress_type=$EGRESS" ${EXTRA[@]+"${EXTRA[@]}"})  # bash 3.2-safe empty array
# upstream's data.external scripts call terraform/jq from PATH; nothing else is needed.
step() { local name=$1; shift; if (cd "$WORK" && "$@") >"$OUT/$name.log" 2>&1; then echo "PASS $name"; else echo "FAIL $name (see $OUT/$name.log)"; return 1; fi; }

step init      terraform init -input=false -reconfigure -backend-config="path=$LOCAL_DIR/state/upstream-conformance-$PROFILE.tfstate" || exit 1
step validate  terraform validate || exit 1
step plan      terraform plan -input=false "${VARS[@]}" -out=c.tfplan || exit 1
if step apply terraform apply -input=false c.tfplan; then
  step idempotency terraform plan -input=false -detailed-exitcode "${VARS[@]}"
  (cd "$WORK" && terraform state list) > "$OUT/state-list.txt"
fi
[ "${KEEP:-0}" = 1 ] || step destroy terraform destroy -auto-approve -input=false "${VARS[@]}"
