#!/usr/bin/env bash
# Uninstall the k3d cluster and (by default) the k3d binary.
#
#   bash scripts/uninstall.sh              # delete cluster + k3d binary, keep images/proxy
#   bash scripts/uninstall.sh --purge      # also remove images, proxy drop-in, saved tars, ~/.k3d
#   bash scripts/uninstall.sh --purge --keep-images
#   bash scripts/uninstall.sh --keep-k3d   # only delete the cluster
#
# Options: --yes, --purge, --keep-images, --keep-k3d, --keep-proxy

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PURGE=0
KEEP_IMAGES=0
KEEP_K3D=0
KEEP_PROXY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge) PURGE=1 ;;
    --keep-images) KEEP_IMAGES=1 ;;
    --keep-k3d) KEEP_K3D=1 ;;
    --keep-proxy) KEEP_PROXY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "$PURGE" == "1" ]]; then
  confirm "PURGE: delete cluster '${CLUSTER_NAME}', Docker images, k3d binary and proxy config?"
else
  confirm "Delete cluster '${CLUSTER_NAME}' and the k3d binary (images are kept)?"
fi

# ----- cluster ---------------------------------------------------------------
if cluster_exists; then
  if k3d_path="$(k3d_bin_path)"; then
    log "Deleting cluster '${CLUSTER_NAME}'..."
    "$k3d_path" cluster delete "$CLUSTER_NAME" || warn "k3d cluster delete returned an error; continuing."
  else
    warn "k3d binary missing but cluster containers exist; removing them with Docker."
    docker rm -f "k3d-${CLUSTER_NAME}-server-0" "k3d-${CLUSTER_NAME}-agent-0" \
      "k3d-${CLUSTER_NAME}-serverlb" "k3d-${CLUSTER_NAME}-tools" >/dev/null 2>&1 || true
    docker network rm "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
else
  log "Cluster '${CLUSTER_NAME}' does not exist."
fi

# k3d normally removes the registry with the cluster; clean up orphans.
if docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
  log "Removing registry container ${REGISTRY_CONTAINER}..."
  docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
fi

# ----- kubeconfig ------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  kubectl config delete-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config unset "users.admin@k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi

# ----- images / caches -------------------------------------------------------
if [[ "$PURGE" == "1" && "$KEEP_IMAGES" != "1" ]]; then
  log "Removing kit Docker images..."
  for img in "${ALL_IMAGES[@]}"; do
    docker rmi -f "$img" >/dev/null 2>&1 || true
  done
fi

if [[ "$PURGE" == "1" ]]; then
  if [[ "$KEEP_IMAGES" != "1" ]]; then
    rm -f "$ROOT_DIR"/images/k3d-base-*.tar 2>/dev/null || true
    rm -rf "$ROOT_DIR/images/cache"
    log "Removed saved image tars and images/cache"
  fi
  rm -rf "$HOME/.k3d"
  log "Removed ~/.k3d"

  if [[ -f "$HOME/.bashrc" ]] && grep -qF "# k3d-on-wsl PATH" "$HOME/.bashrc"; then
    sed -i '/# k3d-on-wsl PATH/{N;d;}' "$HOME/.bashrc"
    log "Removed the k3d PATH block from ~/.bashrc"
  fi
fi

# ----- proxy drop-in ---------------------------------------------------------
if [[ "$PURGE" == "1" && "$KEEP_PROXY" != "1" && -f "$DOCKER_PROXY_DROPIN" ]]; then
  if grep -q "Managed by oceanho-stack-infra" "$DOCKER_PROXY_DROPIN" 2>/dev/null; then
    log "Removing Docker proxy drop-in..."
    as_root rm -f "$DOCKER_PROXY_DROPIN"
    as_root rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
    as_root systemctl daemon-reload
    if docker info >/dev/null 2>&1; then
      warn "Restarting Docker to drop the proxy environment..."
      as_root systemctl restart docker || true
    fi
  fi
fi

# ----- binary ----------------------------------------------------------------
if [[ "$KEEP_K3D" != "1" ]]; then
  if k3d_path="$(k3d_bin_path)"; then
    if [[ "$k3d_path" != "$K3D_BIN" ]]; then
      warn "k3d at ${k3d_path} was not installed by this kit; leaving it in place."
    else
      log "Removing k3d binary: ${k3d_path}"
      if [[ -w "$(dirname "$k3d_path")" ]]; then
        rm -f "$k3d_path"
      else
        as_root rm -f "$k3d_path"
      fi
    fi
  fi
fi

printf '\n'
ok "Uninstall finished."
if [[ "$PURGE" != "1" ]]; then
  printf 'Docker images and proxy config were kept. For a full cleanup:\n'
  printf '  bash scripts/uninstall.sh --purge\n\n'
fi
