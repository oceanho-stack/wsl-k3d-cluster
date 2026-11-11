#!/usr/bin/env bash
# Delete the k3d cluster (Docker images and the k3d binary are kept).

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if ! cluster_exists; then
  ok "Cluster '${CLUSTER_NAME}' does not exist; nothing to delete."
  exit 0
fi

confirm "Delete cluster '${CLUSTER_NAME}' and all of its workloads?"
ensure_k3d
log "Deleting cluster '${CLUSTER_NAME}'..."
"$K3D_BIN" cluster delete "$CLUSTER_NAME"
ok "Cluster deleted. Docker images are kept (use scripts/uninstall.sh --purge to remove them)."
