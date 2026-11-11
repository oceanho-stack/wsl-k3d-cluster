#!/usr/bin/env bash
# Create (or reuse) the k3d cluster. Idempotent.
#
#   bash scripts/up.sh
#
# First run: pulls pinned images, creates the cluster, imports the k3s system
# images, restarts the nodes once, then waits for all core add-ons.
# Later runs: starts the existing cluster if needed, never recreates it.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ensure_k3d
ensure_docker
require_cmd kubectl
configure_docker_proxy

if cluster_exists; then
  log "Cluster '${CLUSTER_NAME}' already exists."
  if ! cluster_running; then
    log "Starting stopped cluster..."
    "$K3D_BIN" cluster start "$CLUSTER_NAME" --wait --timeout "$WAIT_TIMEOUT"
  fi
  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  if ! cluster_images_ok; then
    warn "System images are missing inside the cluster (nodes were probably created before the import step)."
    import_base_images
    log "Restarting nodes so kubelet picks up the imported images..."
    "$K3D_BIN" cluster restart "$CLUSTER_NAME" --wait --timeout "$WAIT_TIMEOUT" >/dev/null
  fi
  wait_for_nodes
  wait_for_system
  print_endpoints
  wsl_hint
  exit 0
fi

preflight_ports
ensure_images

log "Creating cluster '${CLUSTER_NAME}' (k3s ${K3S_VERSION}, ${SERVERS} server / ${AGENTS} agent)..."
args=(
  cluster create "$CLUSTER_NAME"
  --image "rancher/k3s:${K3S_VERSION}"
  --servers "$SERVERS"
  --agents "$AGENTS"
  --api-port "0.0.0.0:${API_PORT}"
  --port "${HTTP_PORT}:80@loadbalancer"
  --port "${HTTPS_PORT}:443@loadbalancer"
  --kubeconfig-update-default
  --kubeconfig-switch-context
  --wait
  --timeout "$WAIT_TIMEOUT"
)

if [[ "${ENABLE_REGISTRY}" == "1" ]]; then
  args+=(--registry-create "${REGISTRY_NAME}:0.0.0.0:${REGISTRY_PORT}")
fi

if [[ -n "${REGISTRY_CONFIG:-}" ]]; then
  args+=(--registry-config "$REGISTRY_CONFIG")
fi

if [[ -n "${K3D_CREATE_EXTRA_ARGS:-}" ]]; then
  # Deliberate word splitting: allow e.g. K3D_CREATE_EXTRA_ARGS="--k3s-arg=..."
  # shellcheck disable=SC2206
  args+=(${K3D_CREATE_EXTRA_ARGS})
fi

"$K3D_BIN" "${args[@]}"

# k3s starts before the import can finish, so its first pull attempts fail.
# Import from the local Docker store, then restart the node containers once:
# after the restart kubelet finds every system image locally and needs no network.
import_base_images
log "Restarting nodes so kubelet picks up the imported images..."
"$K3D_BIN" cluster restart "$CLUSTER_NAME" --wait --timeout "$WAIT_TIMEOUT" >/dev/null

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
wait_for_nodes
wait_for_system
print_endpoints
wsl_hint
