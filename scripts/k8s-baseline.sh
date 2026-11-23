#!/usr/bin/env bash
# Install the cluster baseline SAS needs (what viya4-deployment's "baseline" role does on AKS), using
# only components whose images are reachable through the spoke egress path:
#   * RWX StorageClass sas-rwx-shared (kubernetes/storage)  - stands in for csi-driver-nfs + NFS VM/NetApp
#   * Contour ingress (kubernetes/ingress/contour.yaml, vendored pinned render) - SAS default ingress
source "$(dirname "$0")/lib.sh"; load_env
export KUBECONFIG="$LOCAL_DIR/kubeconfig"
[ -f "$KUBECONFIG" ] || "$ROOT/scripts/kubeconfig.sh" >/dev/null
kubectl apply -k "$ROOT/kubernetes/storage" >/dev/null
kubectl apply -f "$ROOT/kubernetes/ingress/contour.yaml" >/dev/null
kubectl -n sas-rwx-storage rollout status deploy/sas-rwx-local-path-provisioner --timeout=300s
kubectl -n projectcontour rollout status deploy/contour --timeout=300s
kubectl -n projectcontour rollout status ds/envoy --timeout=300s
log "baseline installed"
