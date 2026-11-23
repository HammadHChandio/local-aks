#!/usr/bin/env bash
# Write .local/kubeconfig for the spoke AKS cluster from Terraform output (the upstream module's
# kube_config). Locally the API server is the k3s container: Floci reports its container hostname,
# which only resolves on the compose network, so the server is rewritten to the published localhost
# port (k3s is started with --tls-san=localhost, so the certificate still verifies).
source "$(dirname "$0")/lib.sh"; load_env; floci_trust
OUT="$LOCAL_DIR/kubeconfig"
tf spoke output -raw kube_config > "$OUT.tmp"
grep -q 'server:' "$OUT.tmp" || die "spoke has no kube_config yet (make spoke-apply)"
if [ "$TARGET" = local ]; then
  host=$(sed -nE 's#.*server: https://([^:]+):([0-9]+).*#\1#p' "$OUT.tmp" | head -1)
  port=$(docker port "$host" 6443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
  [ -n "$port" ] || die "k3s container $host has no published API port"
  sed -i -E "s#server: https://[^ ]+#server: https://localhost:$port#" "$OUT.tmp"
fi
mv "$OUT.tmp" "$OUT"; chmod 600 "$OUT"
echo "$OUT"
