#!/usr/bin/env bash
# Install/refresh node_exporter using files in this package directory.
#
# Usage: sudo ./install.sh [--dry-run]

set -euo pipefail

VERSION="1.11.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"

require_local_archive() {
  local archive="$1"
  if [[ ! -r "$archive" ]]; then
    echo "Required offline archive is missing: $archive" >&2
    echo "On a connected workstation, run template/prepare-offline.sh node-exporter and copy the node-exporter folder." >&2
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

ARCHIVE="$DIST_DIR/node_exporter-${VERSION}.linux-amd64.tar.gz"
CURRENT_VERSION="$(/usr/local/bin/node_exporter --version 2>/dev/null | head -1 || true)"
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

echo "== node_exporter install =="

if ! id node_exporter &>/dev/null; then
  run useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi

if [[ "$CURRENT_VERSION" == *"$VERSION"* ]]; then
  echo "node_exporter $VERSION already installed, skipping binary install"
else
  install_local_binary "$ARCHIVE" "node_exporter-${VERSION}.linux-amd64" node_exporter /usr/local/bin/node_exporter
fi

run mkdir -p /var/lib/node_exporter/textfile_collector
run chown -R node_exporter:node_exporter /var/lib/node_exporter

run install -m 0644 "$SCRIPT_DIR/node_exporter.service.tmpl" /etc/systemd/system/node_exporter.service

run systemctl daemon-reload
run systemctl enable node_exporter.service
run systemctl restart node_exporter.service

echo "Done."
