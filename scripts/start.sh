#!/usr/bin/env bash
# Start a stopped cluster and wait for the core add-ons.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! cluster_exists; then
  die "Cluster '${CLUSTER_NAME}' does not exist. Run: make up"
fi
ensure_k3d

if cluster_running; then
  log "Cluster '${CLUSTER_NAME}' is already running."
else
  log "Starting cluster '${CLUSTER_NAME}'..."
  "$K3D_BIN" cluster start "$CLUSTER_NAME" --wait --timeout "$WAIT_TIMEOUT"
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
wait_for_nodes
wait_for_system
print_endpoints
