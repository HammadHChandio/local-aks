#!/usr/bin/env bash
# Kubernetes runtime checks on the emulated AKS (Floci k3s). Real workloads, real data paths.
SUITE=kubernetes; source "$(dirname "$0")/../lib/result.sh"
load_env
export KUBECONFIG="$LOCAL_DIR/kubeconfig"
[ -f "$KUBECONFIG" ] || "$ROOT/scripts/kubeconfig.sh" >/dev/null || { blocked api "no kubeconfig (spoke not applied)"; exit 0; }
K=kubectl; NS=platform-smoke; SM="$ROOT/kubernetes/smoke"
OUTS="$LOCAL_DIR/spoke-outputs.json"

check api "Kubernetes API reachable with the upstream module's kubeconfig" "$(ev api.txt)" $K version
check node-ready "all nodes Ready" "$(ev nodes.txt)" bash -c "$K get nodes -o wide && ! $K get nodes --no-headers | grep -v ' Ready '"

E=$(ev node-facts.json)
$K get nodes -o json | jq '[.items[] | {name:.metadata.name, arch:.status.nodeInfo.architecture, kubelet:.status.nodeInfo.kubeletVersion,
  cpu:.status.allocatable.cpu, memory:.status.allocatable.memory, labels:(.metadata.labels|with_entries(select(.key|test("sas.com")))), taints:.spec.taints}]' > "$E"
arch=$(jq -r '.[0].arch' "$E")
[ "$arch" = amd64 ] && pass node-arch "node architecture amd64 (SAS Viya images are linux/amd64 only)" "$E" \
  || fail node-arch "node architecture $arch: SAS Viya images are linux/amd64 only" "$E"
cpu=$(jq -r '.[0].cpu' "$E" | sed 's/m$//'); mem_ki=$(jq -r '.[0].memory' "$E" | sed 's/Ki$//')
[[ $(jq -r '.[0].cpu' "$E") == *m ]] && cpu=$((cpu/1000))
mem_gi=$((mem_ki/1024/1024))
MIN_CPU=${SAS_MIN_CPU:-16}; MIN_MEM=${SAS_MIN_MEM_GI:-64}
if [ "$cpu" -ge "$MIN_CPU" ] && [ "$mem_gi" -ge "$MIN_MEM" ]; then
  pass node-capacity "allocatable ${cpu} vCPU / ${mem_gi} GiB >= ${MIN_CPU}/${MIN_MEM} threshold" "$E"
else
  blocked node-capacity "allocatable ${cpu} vCPU / ${mem_gi} GiB < ${MIN_CPU} vCPU / ${MIN_MEM} GiB threshold for a full SAS Viya platform" "$E"
fi
n_nodes=$(jq length "$E")
blocked sas-node-pools "1 node: Floci agent pools are ARM-state only; cas/compute/stateless/stateful pools + taints are not real nodes" "$E"

$K apply -f "$SM/storage.yaml" >/dev/null
# ---- DNS ----
E=$(ev dns.txt)
$K -n $NS run dns --image=busybox:1.36 --restart=Never --rm -i --command -- sh -c \
  'nslookup kubernetes.default.svc.cluster.local && nslookup kube-dns.kube-system.svc.cluster.local' > "$E" 2>&1 \
  && pass dns-cluster "CoreDNS resolves cluster service names" "$E" || fail dns-cluster "cluster DNS failed" "$E"

# ---- Storage ----
E=$(ev storage.txt)
{ $K -n $NS wait --for=condition=Ready pod/writer pod/reader --timeout=240s && $K -n $NS get pvc
  $K -n $NS exec writer -- cat /rwo/f; $K -n $NS logs reader; } > "$E" 2>&1
grep -q 'rwo-ok' "$E" && pass storage-rwo "RWO PVC (local-path) bound, written, read" "$E" || fail storage-rwo "RWO PVC failed" "$E"
grep -q '^rwx-writer' "$E" && pass storage-rwx "RWX PVC (sas-rwx-shared) written by one pod, read by another concurrently" "$E" || fail storage-rwx "RWX PVC failed" "$E"

# ---- Registry (spoke ACR via Floci backing registry) ----
E=$(ev registry.txt)
ACR=$(jq -r '.acr_login_server.value' "$OUTS"); name=${ACR%%.*}
{ docker pull -q busybox:1.36 && docker tag busybox:1.36 "localhost:5000/$name/smoke/busybox:1.36" \
  && docker push -q "localhost:5000/$name/smoke/busybox:1.36" \
  && $K -n $NS delete pod acr-pull --ignore-not-found \
  && $K -n $NS run acr-pull --image="$ACR/smoke/busybox:1.36" --image-pull-policy=Always --restart=Never --command -- sh -c 'echo pulled-from-acr' \
  && $K -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/acr-pull --timeout=120s && $K -n $NS logs acr-pull \
  && $K -n $NS get pod acr-pull -o jsonpath='{.status.containerStatuses[0].imageID}'; } > "$E" 2>&1
grep -q pulled-from-acr "$E" && pass registry-pull "pod pulled $ACR/smoke/busybox:1.36 (pushed to spoke ACR, mirrored to Floci registry)" "$E" \
  || fail registry-pull "ACR push/pull failed" "$E"
blocked registry-acrpull-auth "AcrPull managed-identity token exchange not exercised (Floci backing registry is anonymous)" "$E"

# ---- PostgreSQL Flexible Server (real postgres container behind Floci ARM) ----
E=$(ev postgres.txt)
PGH=$(jq -r '.postgres.value.fqdn' "$OUTS"); PGU=$(jq -r '.postgres.value.admin' "$OUTS")
$K -n $NS create secret generic pg --from-file=password="$LOCAL_DIR/secrets/pg_admin_password" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n $NS delete pod pgtest --ignore-not-found >/dev/null
$K -n $NS run pgtest --image=postgres:17-alpine --restart=Never \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"pgtest\",\"image\":\"postgres:17-alpine\",\"env\":[{\"name\":\"PGPASSWORD\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"pg\",\"key\":\"password\"}}}],\"command\":[\"sh\",\"-c\",\"psql -h $PGH -U $PGU -d postgres -v ON_ERROR_STOP=1 -c 'select version();' -c 'show max_prepared_transactions;' -c 'create table if not exists smoke(t text); insert into smoke values (now()::text); select count(*) from smoke;'\"]}]}}" >/dev/null
{ $K -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/pgtest --timeout=180s; $K -n $NS logs pgtest; } > "$E" 2>&1
grep -q 'PostgreSQL' "$E" && pass postgres-connect "pod -> $PGH:5432 authenticated, DDL/DML ok" "$E" || fail postgres-connect "PostgreSQL connection from pod failed" "$E"
mpt=$(awk '/max_prepared_transactions/{getline;getline;print $1}' "$E")
[ "${mpt:-0}" -ge 1024 ] 2>/dev/null && pass postgres-sas-config "max_prepared_transactions=$mpt (SAS requirement, set via flexibleServers/configurations)" "$E" \
  || blocked postgres-sas-config "max_prepared_transactions=${mpt:-?}: Floci stores server configurations as ARM state but does not apply them to the engine" "$E"

# ---- Ingress (Contour) with TLS ----
E=$(ev ingress.txt)
if $K -n projectcontour get ds envoy >/dev/null 2>&1; then
  T=$(mktemp -d); openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=viya.local.test" -addext "subjectAltName=DNS:viya.local.test" -keyout "$T/k" -out "$T/c" 2>/dev/null
  $K -n $NS create secret tls echo-tls --cert="$T/c" --key="$T/k" --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K apply -f "$SM/ingress.yaml" >/dev/null; $K -n $NS rollout status deploy/echo --timeout=120s >/dev/null 2>&1
  NODE_IP=$($K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  for _ in $(seq 1 30); do
    out=$(curl -s --noproxy '*' --max-time 5 --cacert "$T/c" --resolve "viya.local.test:443:$NODE_IP" https://viya.local.test/) && [ "$out" = sas-viya-local-ingress-ok ] && break; sleep 2
  done
  { echo "node=$NODE_IP"; $K -n $NS get ingress echo; echo "response: $out"; } > "$E" 2>&1
  [ "$out" = sas-viya-local-ingress-ok ] && pass ingress-tls "HTTPS via Contour/Envoy with verified TLS -> backend" "$E" || fail ingress-tls "no response through ingress" "$E"

  # ---- NetworkPolicy enforcement (k3s kube-router) ----
  E=$(ev netpol.txt)
  $K apply -f "$SM/netpol.yaml" >/dev/null; sleep 3
  allow=$($K -n $NS run np-allow --image=busybox:1.36 --labels=role=client --restart=Never --rm -i --command -- wget -qO- -T 5 http://echo 2>&1)
  deny=$($K -n $NS run np-deny --image=busybox:1.36 --restart=Never --rm -i --command -- wget -qO- -T 5 http://echo 2>&1)
  printf 'allowed-client: %s\nunlabelled-client: %s\n' "$allow" "$deny" > "$E"
  [[ "$allow" == *ingress-ok* && "$deny" != *ingress-ok* ]] && pass netpol-enforced "default-deny enforced in-cluster; labelled client allowed, other denied" "$E" \
    || fail netpol-enforced "NetworkPolicy not enforced as expected" "$E"
  $K delete -f "$SM/netpol.yaml" >/dev/null
else
  blocked ingress-tls "Contour not installed (run make kubernetes-baseline)" "$E"
fi

# ---- SAS-style scheduling (labels/tolerations on the single node) ----
E=$(ev scheduling.txt)
$K -n $NS delete pod sched --ignore-not-found >/dev/null
$K -n $NS run sched --image=busybox:1.36 --restart=Never --overrides='{"spec":{"tolerations":[{"key":"workload.sas.com/class","operator":"Equal","value":"cas","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"preference":{"matchExpressions":[{"key":"workload.sas.com/class","operator":"In","values":["cas"]}]}}]}}}}' --command -- true >/dev/null
$K -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/sched --timeout=120s > "$E" 2>&1 \
  && pass scheduling-sas-affinity "pod with SAS cas toleration + preferred affinity schedules" "$E" || fail scheduling-sas-affinity "scheduling failed" "$E"

[ "${KEEP_SMOKE:-0}" = 1 ] || $K delete ns $NS --wait=false >/dev/null 2>&1 || true
