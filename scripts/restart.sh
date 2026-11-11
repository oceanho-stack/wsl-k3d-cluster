#!/usr/bin/env bash
# Restart all node containers, then wait for the core add-ons.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! cluster_exists; then
  die "Cluster '${CLUSTER_NAME}' does not exist. Run: make up"
fi
ensure_k3d
log "Restarting cluster '${CLUSTER_NAME}'..."
"$K3D_BIN" cluster restart "$CLUSTER_NAME" --wait --timeout "$WAIT_TIMEOUT"
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
wait_for_nodes
wait_for_system
ok "Cluster restarted."
