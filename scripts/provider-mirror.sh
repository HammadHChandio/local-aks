#!/usr/bin/env bash
# Populate a filesystem provider mirror from releases.hashicorp.com (SHA256-verified) and write a
# Terraform CLI config that installs ONLY from it. Works where registry.terraform.io is blocked
# (air-gapped / egress-restricted build agents) and pins exactly what upstream SAS IaC expects.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="$ROOT/.local/provider-mirror"
OS=$(uname -s | tr 'A-Z' 'a-z'); ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac

# name=version (exact versions satisfying upstream viya4-iac-azure constraints at the vendored commit)
PROVIDERS=(
  azurerm=4.64.0
  azuread=3.6.0
  kubernetes=3.0.1
  external=2.3.5
  local=2.5.3
  null=3.2.4
  tls=4.1.0
  cloudinit=2.3.7
)

for p in "${PROVIDERS[@]}"; do
  name=${p%%=*}; ver=${p#*=}
  dest="$MIRROR/registry.terraform.io/hashicorp/$name/$ver/${OS}_${ARCH}"
  if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then echo "cached  $name $ver"; continue; fi
  base="https://releases.hashicorp.com/terraform-provider-$name/$ver"
  zip="terraform-provider-${name}_${ver}_${OS}_${ARCH}.zip"
  tmp=$(mktemp -d)
  curl -sSfL "$base/$zip" -o "$tmp/$zip"
  curl -sSfL "$base/terraform-provider-${name}_${ver}_SHA256SUMS" -o "$tmp/SUMS"
  (cd "$tmp" && grep " $zip\$" SUMS > ONE && if command -v sha256sum >/dev/null; then sha256sum -c --quiet ONE; else shasum -a 256 -c --quiet ONE; fi) || { echo "checksum FAILED for $zip" >&2; exit 1; }
  mkdir -p "$dest" && unzip -oq "$tmp/$zip" -d "$dest" && rm -rf "$tmp"
  echo "mirrored $name $ver"
done

cat > "$ROOT/.local/terraformrc" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$MIRROR"
    include = ["registry.terraform.io/hashicorp/*"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/*"]
  }
}
plugin_cache_may_break_dependency_lock_file = true
EOF
echo "TF_CLI_CONFIG_FILE=$ROOT/.local/terraformrc"
