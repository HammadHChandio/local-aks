#!/usr/bin/env bash
# SAS Viya readiness gate. Validates software-order assets and platform prerequisites BEFORE any
# deployment is attempted. Each item is PASS, FAIL or BLOCKED with evidence. sas-deploy requires no
# FAIL/BLOCKED here. Nothing in this gate mocks or substitutes SAS components.
SUITE=sas-gate; source "$(dirname "$0")/../lib/result.sh"
load_env
A="$ROOT/sas-viya/assets"; ORDER="$ROOT/sas-viya/order.env"
[ -f "$ORDER" ] && { set -a; . "$ORDER"; set +a; }

# 1. Order assets ---------------------------------------------------------------------------------
E=$(ev assets.txt); ls -la "$A" > "$E" 2>&1
TGZ=$(ls "$A"/*deployment-assets*.tgz 2>/dev/null | head -1); LIC=$(ls "$A"/*.jwt 2>/dev/null | head -1); CRT=$(ls "$A"/*certs*.zip 2>/dev/null | head -1)
if [ -z "$TGZ$LIC$CRT" ]; then
  blocked order-assets "no SAS order assets in sas-viya/assets (deployment-assets .tgz, license .jwt, certs .zip): authorised order required" "$E"
else
  [ -n "$TGZ" ] && tar -tzf "$TGZ" 2>/dev/null | grep -q '^sas-bases/' && pass assets-tgz "$(basename "$TGZ") contains sas-bases/" "$E" \
    || fail assets-tgz "deployment assets missing or without sas-bases/" "$E"
  if [ -n "$LIC" ]; then
    exp=$(cut -d. -f2 "$LIC" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null)
    if [ -n "$exp" ] && [ "$exp" -gt "$(date +%s)" ]; then pass license "license JWT valid until $(date -u -d @"$exp" +%F)" "$E"
    else fail license "license unreadable or expired (exp=${exp:-n/a})" "$E"; fi
  else fail license "license .jwt missing" "$E"; fi
  [ -n "$CRT" ] && unzip -l "$CRT" >/dev/null 2>&1 && pass certs "$(basename "$CRT") readable" "$E" || fail certs "certs .zip missing/unreadable" "$E"
  [ -n "${SAS_ORDER_NUMBER:-}" ] && [ -n "${SAS_CADENCE_VERSION:-}" ] && pass order-env "order $SAS_ORDER_NUMBER cadence ${SAS_CADENCE_NAME:-} $SAS_CADENCE_VERSION" "$E" \
    || fail order-env "sas-viya/order.env missing SAS_ORDER_NUMBER/SAS_CADENCE_VERSION" "$E"
fi

# 2. SAS endpoints through the egress path ------------------------------------------------------
E=$(ev endpoints.txt); : > "$E"
probe() { local url=$1 code; code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$url" || true); echo "$url -> HTTP $code" >> "$E"; echo "$code"; }
c=$(probe https://cr.sas.com/v2/)
[[ "$c" =~ ^(200|401)$ ]] && pass cr-sas-com-reachable "cr.sas.com registry reachable (HTTP $c)" "$E" \
  || blocked cr-sas-com-reachable "cr.sas.com unreachable from this host (HTTP ${c:-000}); SAS images cannot be pulled. Allow it on the hub firewall / proxy or mirror the order to the spoke ACR" "$E"
c=$(probe https://ses.sas.download/)
[[ "$c" =~ ^[234] ]] && pass ses-download-reachable "ses.sas.download reachable (HTTP $c)" "$E" \
  || blocked ses-download-reachable "ses.sas.download unreachable (HTTP ${c:-000}): assets must be pre-downloaded" "$E"

# 3. Licensed image pull (needs assets + registry) ----------------------------------------------
E=$(ev image-pull.txt)
if [ -n "$TGZ" ] && [[ "$(probe https://cr.sas.com/v2/)" =~ ^(200|401)$ ]]; then
  tmp=$(mktemp -d); tar -xzf "$TGZ" -C "$tmp" 2>/dev/null
  img=$(grep -rhoE 'cr\.sas\.com/viya-4-x64_oci_linux_2-docker/sas-readiness:[^" ]+' "$tmp/sas-bases" 2>/dev/null | head -1)
  dcfg=$(grep -rlE '\.dockerconfigjson|cr\.sas\.com' "$tmp/sas-bases/base" 2>/dev/null | head -1)
  { echo "image=$img"; echo "credentials-file=$dcfg"; docker manifest inspect "$img"; } > "$E" 2>&1 \
    && grep -q '"architecture": "amd64"' "$E" && pass licensed-image-manifest "licensed image manifest resolvable: $img" "$E" \
    || fail licensed-image-manifest "cannot resolve licensed image manifest (credentials/entitlement)" "$E"
  rm -rf "$tmp"
else
  echo "requires order assets AND cr.sas.com reachability" > "$E"
  blocked licensed-image-manifest "licensed image pull not attempted: needs order assets and cr.sas.com" "$E"
fi

# 4. Platform prerequisites (from the kubernetes suite's live node facts) -------------------------
F="$EVIDENCE/kubernetes-node-facts.json"
if [ -s "$F" ]; then
  arch=$(jq -r '.[0].arch' "$F")
  [ "$arch" = amd64 ] && pass platform-arch "cluster nodes are amd64" "$F" || fail platform-arch "nodes are $arch; SAS Viya is linux/amd64 only" "$F"
  st=$(jq -r 'map(select(.id=="kubernetes/node-capacity"))|last|.status' <(jq -s . "$RESULTS"))
  [ "$st" = PASS ] && pass platform-capacity "node capacity meets threshold" "$F" || blocked platform-capacity "node capacity below SAS Viya platform threshold (see kubernetes/node-capacity)" "$F"
  for dep in storage-rwx ingress-tls postgres-connect registry-pull; do
    s=$(jq -r --arg id "kubernetes/$dep" 'map(select(.id==$id))|last|.status // "MISSING"' <(jq -s . "$RESULTS"))
    [ "$s" = PASS ] && pass "prereq-$dep" "kubernetes/$dep passed" "$RESULTS" || blocked "prereq-$dep" "kubernetes/$dep is $s" "$RESULTS"
  done
else
  blocked platform "run make kubernetes-verify first (no node facts)" ""
fi
