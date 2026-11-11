#!/usr/bin/env bash
# End-to-end smoke test:
#   1. nodes and core add-ons are Ready
#   2. demo Deployment + Traefik Ingress answer on the mapped HTTP port
#   3. local-path PVC can be mounted and written
#   4. optional: push to the built-in registry and pull it from a Pod
#
#   bash scripts/test.sh
#   KEEP=1 bash scripts/test.sh    # keep the demo namespace for inspection

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cluster_exists || die "Cluster '${CLUSTER_NAME}' does not exist. Run: make up"
cluster_running || die "Cluster '${CLUSTER_NAME}' is stopped. Run: make start"
ensure_k3d
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

require_cmd curl

# Make sure optional test images are available locally, then import them.
missing=()
for img in "${TEST_IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || missing+=("$img")
done
if (( ${#missing[@]} )); then
  warn "Pulling test images: ${missing[*]}"
  bash "$ROOT_DIR/scripts/prepare-images.sh" --all
fi

log "Preparing demo images..."
ensure_test_tars
test_tars=()
for img in "${TEST_IMAGES[@]}"; do
  test_tars+=("$(system_tar_path "$img")")
done
log "Importing demo images into the cluster..."
"$K3D_BIN" image import -c "$CLUSTER_NAME" "${test_tars[@]}" >/dev/null 2>&1 || true

log "Applying demo workload..."
kubectl apply -f "$ROOT_DIR/examples/demo.yaml" >/dev/null
kubectl -n demo rollout status deployment/whoami --timeout="${WAIT_TIMEOUT}"

log "Testing ingress http://127.0.0.1:${HTTP_PORT} (Host: demo.localhost)..."
body=""
for _ in $(seq 1 30); do
  body="$(curl -fsS --max-time 5 -H 'Host: demo.localhost' "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)"
  [[ "$body" == *"Hostname:"* ]] && break
  sleep 2
done
if [[ "$body" != *"Hostname:"* ]]; then
  kubectl -n demo get ingress,pods,svc -o wide || true
  die "Ingress test failed. Check: kubectl -n demo describe ingress whoami; make logs"
fi
ok "Ingress works (whoami answered)"

log "Testing local-path storage..."
kubectl apply -f "$ROOT_DIR/examples/storage.yaml" >/dev/null
kubectl -n demo wait --for=condition=Ready pod/storage-test --timeout="${WAIT_TIMEOUT}" >/dev/null
value=""
for _ in $(seq 1 15); do
  value="$(kubectl -n demo exec storage-test -- cat /data/hello 2>/dev/null || true)"
  [[ "$value" == "ok" ]] && break
  sleep 1
done
[[ "$value" == "ok" ]] || die "PVC write/read test failed."
ok "PVC (local-path) works"

if [[ "${ENABLE_REGISTRY}" == "1" ]]; then
  log "Testing built-in registry localhost:${REGISTRY_PORT}..."
  docker tag "${DEMO_IMAGE}" "localhost:${REGISTRY_PORT}/demo/whoami:test"
  if docker push "localhost:${REGISTRY_PORT}/demo/whoami:test" >/dev/null 2>&1; then
    kubectl -n demo delete pod registry-test --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n demo run registry-test \
      --image="${REGISTRY_NAME}:${REGISTRY_PORT}/demo/whoami:test" \
      --restart=Never --command -- /whoami >/dev/null
    if kubectl -n demo wait --for=condition=Ready pod/registry-test --timeout=120s >/dev/null 2>&1; then
      ok "Registry pull works (${REGISTRY_NAME}:${REGISTRY_PORT})"
    else
      kubectl -n demo describe pod registry-test || true
      warn "Registry push worked, but in-cluster pull failed (see pod events)."
    fi
    kubectl -n demo delete pod registry-test --ignore-not-found >/dev/null 2>&1 || true
  else
    warn "Could not push to localhost:${REGISTRY_PORT}; registry test skipped."
  fi
fi

if [[ "${KEEP:-0}" == "1" ]]; then
  ok "Demo kept in namespace 'demo'."
else
  kubectl delete -f "$ROOT_DIR/examples/demo.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f "$ROOT_DIR/examples/storage.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n demo delete pod registry-test --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace demo --ignore-not-found >/dev/null 2>&1 || true
fi

printf '\n'
ok "All smoke tests passed."
printf 'Try it yourself:\n'
printf '  kubectl apply -f examples/demo.yaml\n'
printf '  curl -H "Host: demo.localhost" http://127.0.0.1:%s/\n\n' "$HTTP_PORT"
