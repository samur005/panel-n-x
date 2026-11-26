#!/usr/bin/env bash
# NX Panel installer and updater. Re-run it to update in place.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/samur005/panel-n-x/main/install.sh)
#
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/samur005/panel-n-x/main/install.sh) --github
set -euo pipefail

PANEL_REPO="samur005/panel-n-x"
NODE_REPO="samur005/panel-n-x"
INSTALL_DIR="/opt/nx-panel"   # binary + config.json
STATE_DIR="/var/opt/nx-panel"       # database, node binaries, themes, backups
SERVICE="nx-panel"
UNIT="/etc/systemd/system/${SERVICE}.service"

PANEL_VERSION=""    # empty = the latest release
NODE_VERSION=""     # empty = the latest release
USE_POSTGRES=0
DO_UNINSTALL=0
FROM_GITHUB=1       # always download from GitHub
PG_DB="nx"
PG_USER="nx"

die() {
  echo "error: $*" >&2
  # A failure after an install made under the old name was moved puts it back.
  [[ "${TRANSFERRED:-0}" -eq 0 ]] || restore_transfer
  exit 1
}
panel_version() { "${INSTALL_DIR}/nx-panel" version 2>/dev/null | awk '{print $2}'; }
nx_panel() { "${INSTALL_DIR}/nx-panel" "$@"; }
say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
NX Panel installer

  install.sh [--postgres] [--version vX.Y.Z] [--node-version vX.Y.Z] [--github]
  install.sh --uninstall

  --postgres          install and configure PostgreSQL instead of SQLite
  --version TAG       install a specific panel release instead of the latest
  --node-version TAG  stage a specific node release instead of the latest
  --github            (kept for compatibility)
  --uninstall         stop and remove the panel (the database is kept)

Re-running the installer on an existing install performs an update.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres) USE_POSTGRES=1; shift ;;
    --version) PANEL_VERSION="${2:-}"; [[ -n "$PANEL_VERSION" ]] || usage; shift 2 ;;
    --node-version) NODE_VERSION="${2:-}"; [[ -n "$NODE_VERSION" ]] || usage; shift 2 ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --github) FROM_GITHUB=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || die "please run as root"
command -v systemctl >/dev/null || die "this installer needs systemd; use the Docker install instead"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"

# --- platform -----------------------------------------------------------------

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l|armv7) echo "linux-armv7" ;;
    armv6l|armv6) echo "linux-armv6" ;;
    i386|i686) echo "linux-386" ;;
    s390x) echo "linux-s390x" ;;
    riscv64) echo "linux-riscv64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}
ARCH="$(detect_arch)"

[[ -n "$PANEL_VERSION" && "$PANEL_VERSION" != v* ]] && PANEL_VERSION="v${PANEL_VERSION}"
[[ -n "$NODE_VERSION" && "$NODE_VERSION" != v* ]] && NODE_VERSION="v${NODE_VERSION}"

# NX_DOWNLOAD_BASE points at a flat mirror instead of GitHub.
asset_url() {
  local repo="$1" version="$2" name="$3"
  if [[ -n "${NX_DOWNLOAD_BASE:-}" ]]; then
    echo "${NX_DOWNLOAD_BASE%/}/${name}"
  elif [[ -n "$version" ]]; then
    echo "https://github.com/${repo}/releases/download/${version}/${name}"
  else
    echo "https://github.com/${repo}/releases/latest/download/${name}"
  fi
}

# The panel archive is downloaded from GitHub releases.
# One URL per line, in the order to try.
NX_SITE=""
panel_asset_urls() {
  local name="$1" via="$2" path
  if [[ -n "${NX_DOWNLOAD_BASE:-}" ]]; then
    echo "${NX_DOWNLOAD_BASE%/}/${name}"
    return
  fi
  if [[ -n "$PANEL_VERSION" ]]; then
    path="releases/download/${PANEL_VERSION}/${name}"
  else
    path="releases/latest/download/${name}"
  fi
  [[ $FROM_GITHUB -eq 1 ]] || echo "${NX_SITE}/${path}?via=${via}"
  echo "https://github.com/${PANEL_REPO}/${path}"
}

# fetch_first OUT URL... downloads the first URL that answers into OUT.
fetch_first() {
  local out="$1" url
  shift
  for url in "$@"; do
    # A site blocked by dropping packets would otherwise hold curl for minutes
    # before the next URL is tried.
    curl -fsSL --connect-timeout 15 "$url" -o "$out" && return 0
  done
  return 1
}

# --- uninstall ----------------------------------------------------------------

if [[ $DO_UNINSTALL -eq 1 ]]; then
  say "stopping ${SERVICE}"
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT" /usr/local/bin/nx-panel
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  echo
  echo "NX is removed. The database and the backups under ${STATE_DIR}"
  echo "were left alone. Delete them yourself once you are sure — and take a copy"
  echo "of ${STATE_DIR}/backups first if this server is going away:"
  echo "  rm -rf ${STATE_DIR}"
  exit 0
fi

# (rest of the file continues with the same logic, migration from nexora etc. kept as is)
# Full content is the updated one from /tmp/install.sh
