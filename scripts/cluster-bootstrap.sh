#!/usr/bin/env bash
# Node-level bootstrap of the emulated AKS (Floci k3s) node. Idempotent; restarts the node once if needed.
#  1. Egress TLS-inspection CA (EGRESS_CA_FILE in .env): hub firewall / corporate proxy re-signs TLS, so
#     containerd must trust that CA to pull images through the spoke's forced-egress path.
#  2. Registry mirror: <acr>.azurecr.io -> Floci's shared backing registry (floci-az-acr-registry:5000,
#     repository prefix <acr>/). Keeps Azure-style image references in manifests. Not exercised locally:
#     the AcrPull managed-identity token exchange (anonymous backing registry).
source "$(dirname "$0")/lib.sh"; load_env
[ "$TARGET" = local ] || die "local only (on AKS: AcrPull role on the kubelet identity + node CA trust)"
ACR=$(jq -r '.acr_login_server.value // empty' "$LOCAL_DIR/spoke-outputs.json" 2>/dev/null || true)
for c in $(docker ps --filter name=floci-az-aks- --format '{{.Names}}'); do
  restart=0
  if [ -n "${EGRESS_CA_FILE:-}" ]; then
    [ -f "$EGRESS_CA_FILE" ] || die "EGRESS_CA_FILE=$EGRESS_CA_FILE not found"
    fp=$(sha256sum "$EGRESS_CA_FILE" | cut -c1-16)
    if ! docker exec "$c" grep -q "egress-ca:$fp" /etc/ssl/certs/ca-certificates.crt; then
      { printf '\n# egress-ca:%s\n' "$fp"; cat "$EGRESS_CA_FILE"; } | docker exec -i "$c" sh -c 'cat >> /etc/ssl/certs/ca-certificates.crt'
      log "$c: trusted egress CA $fp"; restart=1
    fi
  fi
  if [ -n "$ACR" ]; then
    name=${ACR%%.*}
    want=$(cat <<YAML
mirrors:
  "$ACR":
    endpoint: ["http://floci-az-acr-registry:5000"]
    rewrite:
      "^(.*)\$": "$name/\$1"
YAML
)
    have=$(docker exec "$c" cat /etc/rancher/k3s/registries.yaml 2>/dev/null || true)
    if [ "$have" != "$want" ]; then
      printf '%s\n' "$want" | docker exec -i "$c" sh -c 'cat > /etc/rancher/k3s/registries.yaml'
      log "$c: registry mirror $ACR -> floci-az-acr-registry:5000/$name/"; restart=1
    fi
  fi
  if [ $restart = 1 ]; then
    docker restart "$c" >/dev/null
    for _ in $(seq 1 90); do docker exec "$c" kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break; sleep 2; done
  fi
  docker exec "$c" kubectl get nodes --no-headers
done
