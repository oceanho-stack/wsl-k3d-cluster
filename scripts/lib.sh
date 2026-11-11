#!/usr/bin/env bash
# Shared library for the k3d-on-WSL kit.
# Source this file, do not execute it.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/cluster.env}"

# shellcheck source=../config/cluster.env
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -f "${CONFIG_FILE}.local" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}.local"
fi

K3D_TAG="${K3D_VERSION#v}"
K3D_BIN="${K3D_INSTALL_DIR}/k3d"
DOCKER_PROXY_DROPIN="/etc/systemd/system/docker.service.d/10-k3d-proxy.conf"
# `k3d cluster create --registry-create NAME` names the container exactly NAME.
REGISTRY_CONTAINER="${REGISTRY_NAME}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-$ROOT_DIR/images/cache}"
case "$(uname -m)" in
  x86_64|amd64) SKOPEO_ARCH="amd64" ;;
  aarch64|arm64) SKOPEO_ARCH="arm64" ;;
  armv7l) SKOPEO_ARCH="arm" ;;
  *) SKOPEO_ARCH="$(uname -m)" ;;
esac

# Images that k3s v1.35.5 needs to bring up its bundled add-ons.
# They are imported into the cluster, so runtime pulls are not required.
# Re-check with: make images
K3S_SYSTEM_IMAGES=(
  "rancher/mirrored-pause:3.6"
  "rancher/mirrored-coredns-coredns:1.14.3"
  "rancher/local-path-provisioner:v0.0.36"
  "rancher/mirrored-metrics-server:v0.8.1"
  "rancher/klipper-helm:v0.10.0-build20260513"
  "rancher/klipper-lb:v0.4.17"
  "rancher/mirrored-library-traefik:3.6.13"
  "${HELPER_IMAGE}"
)

NODE_IMAGES=(
  "rancher/k3s:${K3S_VERSION}"
  "ghcr.io/k3d-io/k3d-proxy:${K3D_TAG}"
  "ghcr.io/k3d-io/k3d-tools:${K3D_TAG}"
)

if [[ "${ENABLE_REGISTRY}" == "1" ]]; then
  NODE_IMAGES+=("registry:2")
fi

BASE_IMAGES=("${K3S_SYSTEM_IMAGES[@]}")
TEST_IMAGES=("${DEMO_IMAGE}" "${BUSYBOX_IMAGE}")
CORE_IMAGES=("${NODE_IMAGES[@]}" "${K3S_SYSTEM_IMAGES[@]}")
ALL_IMAGES=("${CORE_IMAGES[@]}" "${TEST_IMAGES[@]}")

# ----- output ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

log()  { printf '%s[k3d]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi
  [[ -t 0 ]] || die "Non-interactive shell: re-run with --yes (or ASSUME_YES=1)."
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ----- prerequisites --------------------------------------------------------
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
  done
}

k3d_bin_path() {
  if [[ -x "$K3D_BIN" ]]; then
    printf '%s\n' "$K3D_BIN"
  elif command -v k3d >/dev/null 2>&1; then
    command -v k3d
  else
    return 1
  fi
}

ensure_k3d() {
  local bin
  bin="$(k3d_bin_path)" || die "k3d is not installed. Run: bash scripts/install.sh"
  K3D_BIN="$bin"
  local have
  have="$("$K3D_BIN" version 2>/dev/null | awk '/^k3d version/ {print $3}')"
  if [[ "$have" != "$K3D_VERSION" ]]; then
    warn "k3d ${have:-unknown} found at $K3D_BIN, but this kit pins $K3D_VERSION."
    warn "Run: bash scripts/install.sh --force"
  fi
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed in WSL."
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon is not running, trying to start it..."
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start it: sudo systemctl start docker"
  fi
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    warn "User $(id -un) is not in the docker group. Run: sudo usermod -aG docker $(id -un), then re-login."
    docker info >/dev/null 2>&1 || die "No permission to access Docker."
  fi
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    die "This step needs root: sudo $*"
  fi
}

# ----- kernel limits ---------------------------------------------------------
# k3s containerd (CRI "cni conf monitor") and kube-apiserver create inotify
# instances, and the per-UID budget is shared with every root container on the
# machine. With the stock 128 the CRI plugin fails to load
# ("failed to create fsnotify watcher: too many open files") and k3d only sees
# "agent failed to get ready ... context deadline exceeded" before rolling back.
# See docs/04-pitfalls.md 坑 21.
ensure_inotify_limits() {
  local want_i="${INOTIFY_MAX_USER_INSTANCES:-8192}"
  local want_w="${INOTIFY_MAX_USER_WATCHES:-2097152}"
  local want_q="${INOTIFY_MAX_QUEUED_EVENTS:-65536}"
  local f="${INOTIFY_SYSCTL_FILE:-/etc/sysctl.d/99-k3d-inotify.conf}"
  local cur_i cur_w cur_q desired tmp

  cur_i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || true)"
  cur_w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || true)"
  cur_q="$(sysctl -n fs.inotify.max_queued_events 2>/dev/null || true)"
  [[ "$cur_i" =~ ^[0-9]+$ ]] || cur_i=0
  [[ "$cur_w" =~ ^[0-9]+$ ]] || cur_w=0
  [[ "$cur_q" =~ ^[0-9]+$ ]] || cur_q=0

  if (( cur_i >= want_i && cur_w >= want_w && cur_q >= want_q )); then
    # Values are fine for this boot; just make sure the managed file keeps them
    # across WSL restarts. Never lower a value that is already higher.
    desired="# Managed by k3d-on-wsl (scripts/install.sh). Do not edit.
# k3s containerd (CRI cni-conf monitor) and kube-apiserver create inotify
# instances; the per-UID limit is shared with every root container on this box.
# These are caps, not reservations: only watches that exist use kernel memory.
fs.inotify.max_user_instances = ${want_i}
fs.inotify.max_user_watches = ${want_w}
fs.inotify.max_queued_events = ${want_q}"
    tmp="$(mktemp)"
    printf '%s\n' "$desired" >"$tmp"
    if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then
      rm -f "$tmp"
    elif ( as_root install -D -m 0644 "$tmp" "$f" ) 2>/dev/null; then
      rm -f "$tmp"
      log "Wrote $f (takes effect from the next WSL boot)"
    else
      rm -f "$tmp"
      warn "Could not write ${f}; limits will not survive a WSL restart. See docs/01-install.md 1.4."
    fi
    ok "inotify limits ok (instances=${cur_i} watches=${cur_w} queued=${cur_q})"
    return 0
  fi

  warn "inotify limits are low for k3s: instances=${cur_i} (want ${want_i}), watches=${cur_w} (want ${want_w}), queued=${cur_q} (want ${want_q})."
  warn "With the stock 128, containerd's CRI plugin can fail to load and the cluster create rolls back (docs/04-pitfalls.md, 坑 21)."

  desired="# Managed by k3d-on-wsl (scripts/install.sh). Do not edit.
# k3s containerd (CRI cni-conf monitor) and kube-apiserver create inotify
# instances; the per-UID limit is shared with every root container on this box.
# These are caps, not reservations: only watches that exist use kernel memory.
fs.inotify.max_user_instances = ${want_i}
fs.inotify.max_user_watches = ${want_w}
fs.inotify.max_queued_events = ${want_q}"

  tmp="$(mktemp)"
  printf '%s\n' "$desired" >"$tmp"

  if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    log "sysctl file already matches: $f"
  else
    if ! ( as_root install -D -m 0644 "$tmp" "$f" ) 2>/dev/null; then
      rm -f "$tmp"
      warn "Could not write ${f}; raise the limits manually:"
      warn "  sudo bash -c 'printf \"%s\\n\" ... > ${f} && sysctl --system'   (see docs/01-install.md 1.4)"
      return 1
    fi
    rm -f "$tmp"
    log "Wrote $f"
  fi

  if ! ( as_root sysctl --system ) >/dev/null 2>&1; then
    warn "Could not apply sysctl settings (needs root). Run: sudo sysctl --system"
    return 1
  fi

  cur_i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  cur_w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  cur_q="$(sysctl -n fs.inotify.max_queued_events 2>/dev/null || echo 0)"
  if (( cur_i >= want_i && cur_w >= want_w && cur_q >= want_q )); then
    ok "inotify limits raised (instances=${cur_i} watches=${cur_w} queued=${cur_q})"
    return 0
  fi

  warn "inotify limits still below target (instances=${cur_i} watches=${cur_w} queued=${cur_q}); check /etc/sysctl.conf and other /etc/sysctl.d/*.conf files."
  return 1
}

# ----- docker proxy ---------------------------------------------------------
is_docker_desktop() {
  docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'Docker Desktop'
}

configure_docker_proxy() {
  [[ -n "${PROXY_URL}" ]] || return 0

  if is_docker_desktop; then
    warn "Docker Desktop detected: configure the proxy in Docker Desktop settings, skipping daemon drop-in."
    return 0
  fi

  local desired tmp changed=0
  desired="# Managed by oceanho-stack-infra (k3d-on-wsl). Do not edit.
[Service]
Environment=\"HTTP_PROXY=${PROXY_URL}\"
Environment=\"HTTPS_PROXY=${PROXY_URL}\"
Environment=\"NO_PROXY=${NO_PROXY_LIST}\""

  tmp="$(mktemp)"
  printf '%s\n' "$desired" >"$tmp"

  if [[ -f "$DOCKER_PROXY_DROPIN" ]] && cmp -s "$tmp" "$DOCKER_PROXY_DROPIN"; then
    rm -f "$tmp"
    log "Docker proxy already configured (${PROXY_URL})"
    return 0
  fi

  log "Configuring Docker daemon proxy: ${PROXY_URL}"
  as_root install -D -m 0644 "$tmp" "$DOCKER_PROXY_DROPIN"
  rm -f "$tmp"
  changed=1

  if [[ "$changed" == "1" ]]; then
    as_root systemctl daemon-reload
    log "Restarting Docker to apply the proxy (running containers will restart)..."
    as_root systemctl restart docker
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker did not come back after restart."
  fi
}

# ----- cluster helpers ------------------------------------------------------
cluster_exists() {
  docker inspect "k3d-${CLUSTER_NAME}-server-0" >/dev/null 2>&1
}

cluster_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "k3d-${CLUSTER_NAME}-server-0" 2>/dev/null)" == "true" ]]
}

use_cluster_context() {
  kubectl config get-contexts "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 \
    || die "kubeconfig context k3d-${CLUSTER_NAME} not found. Run: make up"
  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
}

port_busy() {
  local port="$1"
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

preflight_ports() {
  local p
  for p in "$API_PORT" "$HTTP_PORT" "$HTTPS_PORT"; do
    if port_busy "$p"; then
      die "TCP port ${p} is already in use. Change it in config/cluster.env.local or stop the other process (ss -lntp | grep :${p})."
    fi
  done
  if [[ "${ENABLE_REGISTRY}" == "1" ]] && port_busy "$REGISTRY_PORT"; then
    die "TCP port ${REGISTRY_PORT} is already in use (often Harbor). Change REGISTRY_PORT."
  fi
}

wait_for_nodes() {
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    if kubectl wait --for=condition=Ready node --all --timeout=30s >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  kubectl get nodes -o wide || true
  die "Nodes did not become Ready. Inspect: make status; make logs"
}

wait_for_system() {
  local d
  for d in coredns traefik local-path-provisioner metrics-server; do
    log "Waiting for kube-system/${d} ..."
    for _ in $(seq 1 90); do
      kubectl -n kube-system get deployment "$d" >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl -n kube-system rollout status "deployment/${d}" --timeout="${WAIT_TIMEOUT}" >/dev/null \
      || die "Deployment ${d} did not become available. Run: make status; make logs"
    ok "kube-system/${d} available"
  done
}

# ----- images ---------------------------------------------------------------
mirror_ref() {
  local img="$1"
  case "$img" in
    ghcr.io/*)   printf '%s/%s\n' "${GHCR_MIRROR%/}" "${img#ghcr.io/}" ;;
    docker.io/*) printf '%s/%s\n' "${DOCKERHUB_MIRROR%/}" "${img#docker.io/}" ;;
    */*)         printf '%s/%s\n' "${DOCKERHUB_MIRROR%/}" "$img" ;;
    *)           printf '%s/library/%s\n' "${DOCKERHUB_MIRROR%/}" "$img" ;;
  esac
}

system_tar_path() {
  local img="$1"
  printf '%s/%s.tar\n' "$IMAGE_CACHE_DIR" "$(printf '%s' "$img" | tr ':/' '__')"
}

ensure_skopeo() {
  command -v skopeo >/dev/null 2>&1 && return 0
  warn "skopeo is required to build single-platform archives (Docker 29 containerd store cannot docker-save multi-arch images reliably)."
  command -v apt-get >/dev/null 2>&1 || die "Install skopeo manually, then re-run."
  log "Installing skopeo..."
  if [[ -n "${PROXY_URL}" ]]; then
    as_root env HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" NO_PROXY="$NO_PROXY_LIST" \
      apt-get install -y skopeo >/dev/null
  else
    as_root apt-get install -y skopeo >/dev/null
  fi
  command -v skopeo >/dev/null 2>&1 || die "skopeo installation failed."
}

skopeo_source_ref() {
  local img="$1"
  case "$img" in
    */*) printf '%s\n' "$img" ;;
    *)   printf 'docker.io/library/%s\n' "$img" ;;
  esac
}

skopeo_copy() {
  local img="$1" tar="$2" src m
  src="docker://$(skopeo_source_ref "$img")"
  mkdir -p "$IMAGE_CACHE_DIR"
  rm -f "$tar"

  local -a envs=()
  if [[ -n "${PROXY_URL}" ]]; then
    envs=(HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" NO_PROXY="$NO_PROXY_LIST")
  fi

  if env "${envs[@]}" skopeo copy --override-os linux --override-arch "$SKOPEO_ARCH" \
      --retry-times 3 "$src" "docker-archive:${tar}:${img}" >/dev/null 2>"${tar}.err"; then
    rm -f "${tar}.err"
    return 0
  fi

  m="$(mirror_ref "$img")"
  m="${m#https://}"; m="${m#http://}"
  if [[ "$m" != "$img" ]]; then
    if env "${envs[@]}" skopeo copy --override-os linux --override-arch "$SKOPEO_ARCH" \
        --retry-times 3 "docker://${m}" "docker-archive:${tar}:${img}" >/dev/null 2>"${tar}.err"; then
      rm -f "${tar}.err"
      return 0
    fi
  fi

  warn "skopeo export failed for ${img}:"
  cat "${tar}.err" >&2 || true
  rm -f "$tar" "${tar}.err"
  return 1
}

build_system_tars() {
  local force="${1:-0}" img tar
  ensure_skopeo
  for img in "${K3S_SYSTEM_IMAGES[@]}"; do
    tar="$(system_tar_path "$img")"
    if [[ "$force" != "1" && -s "$tar" ]]; then
      printf '  %-58s cached\n' "$img"
      continue
    fi
    printf '  %-58s exporting\n' "$img"
    skopeo_copy "$img" "$tar" || die "Failed to export ${img}. Check proxy/mirror."
    printf '  %-58s ok (%s)\n' "$img" "$(du -h "$tar" | cut -f1)"
  done
}

ensure_test_tars() {
  local img tar missing=()
  for img in "${TEST_IMAGES[@]}"; do
    tar="$(system_tar_path "$img")"
    [[ -s "$tar" ]] || missing+=("$img")
  done
  (( ${#missing[@]} == 0 )) && return 0
  ensure_skopeo
  for img in "${missing[@]}"; do
    tar="$(system_tar_path "$img")"
    log "Exporting test image ${img}..."
    skopeo_copy "$img" "$tar" || die "Failed to export ${img}."
  done
}

ensure_system_tars() {
  local img tar missing=()
  for img in "${K3S_SYSTEM_IMAGES[@]}"; do
    tar="$(system_tar_path "$img")"
    [[ -s "$tar" ]] || missing+=("$img")
  done
  (( ${#missing[@]} == 0 )) && return 0
  warn "Missing single-platform archives for: ${missing[*]}"
  warn "Building them now (needs network once, skopeo)..."
  bash "$ROOT_DIR/scripts/prepare-images.sh" --system-tars
}

images_present_in_node() {
  local node="$1" img name tag listing
  listing="$(docker exec "k3d-${CLUSTER_NAME}-${node}-0" crictl images 2>/dev/null || true)"
  for img in "${K3S_SYSTEM_IMAGES[@]}"; do
    name="${img%:*}"      # rancher/mirrored-pause
    name="${name##*/}"    # mirrored-pause
    tag="${img##*:}"      # 3.6
    if ! awk -v n="$name" -v t="$tag" 'index($0,n) && $2==t {found=1} END{exit !found}' <<<"$listing"; then
      return 1
    fi
  done
  return 0
}

cluster_images_ok() {
  images_present_in_node server && images_present_in_node agent
}

verify_imported() {
  local node="$1"
  if ! images_present_in_node "$node"; then
    die "One or more system images are missing in node ${node}. Re-run: bash scripts/up.sh"
  fi
}

missing_images() {
  local scope="${1:-core}" img
  local -a list
  if [[ "$scope" == "all" ]]; then
    list=("${ALL_IMAGES[@]}")
  else
    list=("${CORE_IMAGES[@]}")
  fi
  for img in "${list[@]}"; do
    docker image inspect "$img" >/dev/null 2>&1 || printf '%s\n' "$img"
  done
}

ensure_images() {
  local missing=()
  mapfile -t missing < <(missing_images core)
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  warn "Missing local images: ${missing[*]}"
  if [[ "${PREPARE_IMAGES}" != "1" ]]; then
    die "Run: bash scripts/prepare-images.sh   (or set PREPARE_IMAGES=1)"
  fi
  log "Pulling missing images (one-time, may use the configured proxy/mirror)..."
  bash "$ROOT_DIR/scripts/prepare-images.sh" --core
}

import_base_images() {
  [[ "${IMPORT_IMAGES}" == "1" ]] || { warn "IMPORT_IMAGES=0, skipping image import"; return 0; }
  ensure_system_tars

  local img tar
  local -a tars=()
  for img in "${K3S_SYSTEM_IMAGES[@]}"; do
    tar="$(system_tar_path "$img")"
    [[ -s "$tar" ]] || die "Missing image archive: $tar"
    tars+=("$tar")
  done

  log "Importing ${#tars[@]} single-platform image archives into cluster '${CLUSTER_NAME}'..."
  mkdir -p "$ROOT_DIR/.tmp"
  local import_log="$ROOT_DIR/.tmp/k3d-image-import.log"
  : >"$import_log"
  if ! "$K3D_BIN" image import -c "$CLUSTER_NAME" "${tars[@]}" >>"$import_log" 2>&1; then
    warn "Batch import returned an error; see ${import_log}"
  fi

  if ! cluster_images_ok; then
    warn "Batch import incomplete; retrying archives one by one..."
    for tar in "${tars[@]}"; do
      "$K3D_BIN" image import -c "$CLUSTER_NAME" "$tar" >>"$import_log" 2>&1 || true
    done
  fi

  verify_imported server
  verify_imported agent
  ok "Base images imported and verified"
}

# ----- misc -----------------------------------------------------------------
print_endpoints() {
  printf '\n'
  ok "Cluster '${CLUSTER_NAME}' is ready."
  printf '  kubectl context : k3d-%s\n' "$CLUSTER_NAME"
  printf '  API             : https://127.0.0.1:%s\n' "$API_PORT"
  printf '  HTTP ingress    : http://127.0.0.1:%s  (use a Host header, e.g. demo.localhost)\n' "$HTTP_PORT"
  printf '  HTTPS ingress   : https://127.0.0.1:%s\n' "$HTTPS_PORT"
  if [[ "${ENABLE_REGISTRY}" == "1" ]]; then
    printf '  Local registry  : localhost:%s  (in-cluster: %s:%s)\n' "$REGISTRY_PORT" "$REGISTRY_NAME" "$REGISTRY_PORT"
  fi
  printf '  Status          : make status\n'
  printf '  Smoke test      : make test\n\n'
}

wsl_hint() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    dim "WSL detected. If the cluster disappears after a Windows reboot, open WSL once: wsl.exe -d ${WSL_DISTRO_NAME:-Ubuntu-22.04}"
  fi
}
