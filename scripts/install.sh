#!/usr/bin/env bash
# Install the pinned k3d binary into WSL and prepare Docker for k3d.
#
# Usage:
#   bash scripts/install.sh
#   bash scripts/install.sh --force
#   bash scripts/install.sh --proxy http://192.168.0.111:7897
#
# The script is idempotent: a matching k3d version is left untouched.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --version) K3D_VERSION="$2"; K3D_TAG="${K3D_VERSION#v}"; shift ;;
    --dir) K3D_INSTALL_DIR="$2"; K3D_BIN="$K3D_INSTALL_DIR/k3d"; shift ;;
    --proxy) PROXY_URL="$2"; shift ;;
    --no-checksum) SKIP_CHECKSUM=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Linux" ]] || die "This kit must run inside WSL/Linux."
require_cmd curl tar sha256sum

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="arm" ;;
  i386|i686) ARCH="386" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

# Route the k3d download through the Windows proxy when one is configured.
if [[ -n "${PROXY_URL}" ]]; then
  export HTTP_PROXY="${HTTP_PROXY:-$PROXY_URL}"
  export HTTPS_PROXY="${HTTPS_PROXY:-$PROXY_URL}"
  log "Using proxy for downloads: ${PROXY_URL}"
fi

need_install=1
if [[ -x "$K3D_BIN" && "$FORCE" != "1" ]]; then
  have="$("$K3D_BIN" version 2>/dev/null | awk '/^k3d version/ {print $3}')"
  if [[ "$have" == "$K3D_VERSION" ]]; then
    ok "k3d ${K3D_VERSION} already installed at ${K3D_BIN}"
    need_install=0
  fi
fi

if [[ "$need_install" == "1" ]]; then
  mkdir -p "$K3D_INSTALL_DIR"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"
  prefix="${K3D_DOWNLOAD_MIRROR%/}"
  if [[ -n "$prefix" ]]; then
    prefix="${prefix}/"
  fi
  bin_url="${prefix}${base}/k3d-linux-${ARCH}"
  sum_url="${prefix}${base}/checksums.txt"

  log "Downloading k3d ${K3D_VERSION} (${ARCH})..."
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "${tmpdir}/k3d" "$bin_url" \
    || die "Download failed: $bin_url"

  if [[ "${SKIP_CHECKSUM}" != "1" ]]; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "${tmpdir}/checksums.txt" "$sum_url" \
      || die "Could not download checksums.txt (use --no-checksum to override)"
    expected="$(awk -v f="k3d-linux-${ARCH}" '$2 == f {print $1}' "${tmpdir}/checksums.txt")"
    [[ -n "$expected" ]] || die "No checksum entry for k3d-linux-${ARCH}"
    actual="$(sha256sum "${tmpdir}/k3d" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for k3d ${K3D_VERSION}"
    ok "Checksum verified"
  fi

  if [[ -w "$K3D_INSTALL_DIR" ]]; then
    install -m 0755 "${tmpdir}/k3d" "$K3D_BIN"
  else
    as_root install -m 0755 "${tmpdir}/k3d" "$K3D_BIN"
  fi
  ok "Installed: $("$K3D_BIN" version | head -1)"
fi

# Put the install dir on PATH for interactive shells (idempotent).
if [[ "$K3D_INSTALL_DIR" != "/usr/local/bin" ]]; then
  if [[ -f "$HOME/.bashrc" ]] && ! grep -qF "# k3d-on-wsl PATH" "$HOME/.bashrc"; then
    {
      printf '\n# k3d-on-wsl PATH\n'
      printf 'export PATH="%s:$PATH"\n' "$K3D_INSTALL_DIR"
    } >>"$HOME/.bashrc"
    dim "Added ${K3D_INSTALL_DIR} to PATH in ~/.bashrc (open a new shell to use it)."
  fi
fi

# ----- Docker prerequisites --------------------------------------------------
ensure_docker

if command -v systemctl >/dev/null 2>&1; then
  if [[ "$(systemctl is-enabled docker 2>/dev/null || true)" != "enabled" ]]; then
    log "Enabling Docker at WSL boot (systemd)..."
    as_root systemctl enable docker >/dev/null
  fi
fi

# k3s containerd's CRI plugin cannot start if the inotify instance budget is
# exhausted by other root containers (kind clusters, builds). Idempotent: only
# touched when the current limits are below the configured targets.
ensure_inotify_limits || warn "Cluster creation may fail until the inotify limits are raised (docs/04-pitfalls.md, 坑 21)."

configure_docker_proxy

if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl is not installed. The cluster can be created, but status/test/up waits need kubectl."
  warn "Install: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
fi

# ----- final checks ----------------------------------------------------------
printf '\n'
"$K3D_BIN" version
printf '\n'
docker info --format 'Docker: {{.ServerVersion}}  storage={{.Driver}}  cgroup={{.CgroupDriver}}' 2>/dev/null || true
ok "Installation complete."
printf 'Next: bash scripts/prepare-images.sh\n'
printf 'Then: bash scripts/up.sh\n\n'
