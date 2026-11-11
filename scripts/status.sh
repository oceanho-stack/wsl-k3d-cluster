#!/usr/bin/env bash
# Human-readable status of the k3d cluster and its endpoints.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

printf '\n=== Versions ===\n'
if k3d_path="$(k3d_bin_path)"; then
  "$k3d_path" version
else
  printf 'k3d: not installed\n'
fi
printf 'docker: %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'not running')"

printf '\n=== Cluster ===\n'
if cluster_exists; then
  if cluster_running; then
    printf 'cluster: %s (running)\n' "$CLUSTER_NAME"
  else
    printf 'cluster: %s (stopped)\n' "$CLUSTER_NAME"
  fi
else
  printf 'cluster: %s (not created)\n' "$CLUSTER_NAME"
fi

printf '\n=== Containers ===\n'
docker ps -a --filter "name=k3d-" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

if ! cluster_exists; then
  printf '\nRun: make up\n\n'
  exit 0
fi

if ! cluster_running; then
  printf '\nCluster is stopped. Run: make start\n\n'
  exit 0
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true

printf '\n=== Nodes ===\n'
kubectl get nodes -o wide 2>/dev/null || true

printf '\n=== Pods ===\n'
kubectl get pods -A 2>/dev/null || true

printf '\n=== Ingress ===\n'
kubectl get ingress -A 2>/dev/null || true

printf '\n=== Services ===\n'
kubectl get svc -A 2>/dev/null || true

printf '\n=== Endpoints ===\n'
printf '  API           https://127.0.0.1:%s\n' "$API_PORT"
printf '  HTTP ingress  http://127.0.0.1:%s\n' "$HTTP_PORT"
printf '  HTTPS ingress https://127.0.0.1:%s\n' "$HTTPS_PORT"
if [[ "${ENABLE_REGISTRY}" == "1" ]]; then
  printf '  Registry      localhost:%s (in-cluster %s:%s)\n' "$REGISTRY_PORT" "$REGISTRY_NAME" "$REGISTRY_PORT"
fi
printf '\n'
