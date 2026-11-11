#!/usr/bin/env bash
# Stop the cluster containers without deleting any state.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! cluster_exists; then
  die "Cluster '${CLUSTER_NAME}' does not exist. Run: make up"
fi
ensure_k3d
log "Stopping cluster '${CLUSTER_NAME}'..."
"$K3D_BIN" cluster stop "$CLUSTER_NAME"
ok "Cluster stopped (state is preserved). Start it with: make start"
