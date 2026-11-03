#!/usr/bin/env bash
# Install/refresh process-exporter using files in this package directory.
#
# Usage: sudo ./install.sh [--dry-run]
# Review config.yml before running.

set -euo pipefail

VERSION="0.8.7"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.yml}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "process-exporter config not found at $CONFIG_FILE" >&2
  exit 1
fi
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"

require_local_archive() {
  local archive="$1"
  if [[ ! -r "$archive" ]]; then
    echo "Required offline archive is missing: $archive" >&2
    echo "On a connected workstation, run template/prepare-offline.sh process-exporter and copy the process-exporter folder." >&2
    return 1
  fi
  if [[ ! -r "$DIST_DIR/SHA256SUMS" ]]; then
    echo "Archive checksum file is missing: $DIST_DIR/SHA256SUMS" >&2
    return 1
  fi
  (cd "$DIST_DIR" && sha256sum -c SHA256SUMS)
}

install_local_binary() {
  local archive="$1"
  local extracted_dir="$2"
  local binary_name="$3"
  local destination="$4"

  if $DRY_RUN; then
    printf '[dry-run] extract %s and install %s/%s -> %s\n' \
      "$archive" "$extracted_dir" "$binary_name" "$destination"
    return 0
  fi

  (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    tar -xzf "$archive" -C "$tmp"
    install -m 0755 "$tmp/$extracted_dir/$binary_name" "$destination"
  )
}

for command_name in tar install systemctl sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required host command not found: $command_name" >&2
    exit 1
  fi
done

ARCHIVE="$DIST_DIR/process-exporter-${VERSION}.linux-amd64.tar.gz"
CURRENT_VERSION="$(/usr/local/bin/process-exporter --version 2>/dev/null | head -1 || true)"
if [[ "$CURRENT_VERSION" != *"$VERSION"* ]]; then
  require_local_archive "$ARCHIVE"
fi

run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

echo "== process-exporter install =="
# The committed unit runs this as root (needs /proc access across
# users), so no dedicated system user is created here.

if [[ "$CURRENT_VERSION" == *"$VERSION"* ]]; then
  echo "process-exporter $VERSION already installed, skipping binary install"
else
  install_local_binary "$ARCHIVE" "process-exporter-${VERSION}.linux-amd64" process-exporter /usr/local/bin/process-exporter
fi

run mkdir -p /etc/process-exporter
run install -m 0644 "$CONFIG_FILE" /etc/process-exporter/config.yml

run install -m 0644 "$SCRIPT_DIR/process_exporter.service.tmpl" /etc/systemd/system/process-exporter.service

run systemctl daemon-reload
run systemctl enable process-exporter.service
run systemctl restart process-exporter.service

echo "Done."
