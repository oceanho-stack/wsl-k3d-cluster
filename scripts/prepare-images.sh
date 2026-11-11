#!/usr/bin/env bash
# Pull/export every image the kit needs.
#
# Two caches are maintained:
#   1. WSL Docker image store  -> used by k3d itself (node images)
#   2. images/cache/*.tar      -> single-platform Docker archives used by
#                                 `k3d image import` (Docker 29 + containerd
#                                 image store cannot reliably `docker save`
#                                 multi-arch images; skopeo solves that)
#
# Usage:
#   bash scripts/prepare-images.sh              # core + demo/test
#   bash scripts/prepare-images.sh --core       # only what the cluster needs
#   bash scripts/prepare-images.sh --system-tars# only rebuild import archives
#   bash scripts/prepare-images.sh --save       # portable tar of all archives
#   bash scripts/prepare-images.sh --force      # re-pull/re-export

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCOPE="all"
SAVE=0
FORCE=0
SYSTEM_TARS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core) SCOPE="core" ;;
    --all) SCOPE="all" ;;
    --system-tars) SYSTEM_TARS_ONLY=1 ;;
    --save) SAVE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "$SYSTEM_TARS_ONLY" == "1" ]]; then
  build_system_tars "$FORCE"
  ok "System image archives are ready in ${IMAGE_CACHE_DIR}"
  exit 0
fi

ensure_docker

if [[ "$SCOPE" == "core" ]]; then
  IMAGES=("${CORE_IMAGES[@]}")
else
  IMAGES=("${ALL_IMAGES[@]}")
fi

pull_one() {
  local img="$1"
  if [[ "$FORCE" != "1" ]] && docker image inspect "$img" >/dev/null 2>&1; then
    printf '  %-58s cached\n' "$img"
    return 0
  fi

  printf '  %-58s pulling\n' "$img"
  if timeout "${PULL_TIMEOUT}" docker pull -q "$img" >/dev/null 2>&1; then
    printf '  %-58s ok\n' "$img"
    return 0
  fi

  local m
  m="$(mirror_ref "$img")"
  if [[ "$m" == "$img" ]]; then
    printf '  %-58s FAILED\n' "$img"
    return 1
  fi

  printf '  %-58s retry via mirror\n' "$img"
  if timeout "${PULL_TIMEOUT}" docker pull -q "$m" >/dev/null 2>&1; then
    docker tag "$m" "$img"
    printf '  %-58s ok (mirror)\n' "$img"
    return 0
  fi

  printf '  %-58s FAILED\n' "$img"
  return 1
}

log "Image scope: ${SCOPE} (${#IMAGES[@]} images)"
log "Docker Hub mirror: ${DOCKERHUB_MIRROR}"
log "GHCR mirror:       ${GHCR_MIRROR}"
[[ -n "${PROXY_URL}" ]] && log "Proxy:             ${PROXY_URL}"

failed_core=()
failed_test=()
for img in "${IMAGES[@]}"; do
  if pull_one "$img"; then
    continue
  fi
  is_core=0
  for c in "${CORE_IMAGES[@]}"; do
    [[ "$c" == "$img" ]] && is_core=1 && break
  done
  if [[ "$is_core" == "1" ]]; then
    failed_core+=("$img")
  else
    failed_test+=("$img")
  fi
done

if (( ${#failed_core[@]} )); then
  warn "Core images failed: ${failed_core[*]}"
  warn "Fix the network/proxy, or set DOCKERHUB_MIRROR/GHCR_MIRROR in config/cluster.env.local."
  exit 1
fi

# Always make sure the single-platform import archives exist.
build_system_tars "$FORCE"

if [[ "$SAVE" == "1" ]]; then
  ensure_skopeo
  log "Exporting all ${#ALL_IMAGES[@]} images as single-platform archives..."
  for img in "${ALL_IMAGES[@]}"; do
    tar="$(system_tar_path "$img")"
    if [[ "$FORCE" != "1" && -s "$tar" ]]; then
      printf '  %-58s cached\n' "$img"
      continue
    fi
    printf '  %-58s exporting\n' "$img"
    skopeo_copy "$img" "$tar" || die "Failed to export ${img}."
  done

  mkdir -p "$ROOT_DIR/images"
  bundle="$ROOT_DIR/images/k3d-base-${K3S_VERSION}.tar"
  log "Packaging archives into ${bundle} ..."
  tar -C "$IMAGE_CACHE_DIR" -cf "$bundle" .
  ok "Saved: $bundle ($(du -h "$bundle" | cut -f1))"
  printf 'On the target machine:\n'
  printf '  mkdir -p images/cache && tar -xf images/%s -C images/cache\n' "$(basename "$bundle")"
  printf '  for f in images/cache/*.tar; do docker load -i "$f"; done\n'
  printf '  make up\n\n'
fi

if (( ${#failed_test[@]} )); then
  warn "Optional test images failed: ${failed_test[*]}"
  warn "'make up' still works; 'make test' needs ${DEMO_IMAGE} and ${BUSYBOX_IMAGE}."
fi

ok "All required images and archives are ready."
