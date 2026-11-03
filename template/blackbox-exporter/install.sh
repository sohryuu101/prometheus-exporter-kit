#!/usr/bin/env bash
# Install/refresh blackbox_exporter using files in this package directory.
#
# Usage: sudo ./install.sh [--dry-run]
# Site values are only needed to render the Prometheus job (done by package.sh).

set -euo pipefail

VERSION="0.28.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"

require_local_archive() {
  local archive="$1"
  if [[ ! -r "$archive" ]]; then
    echo "Required offline archive is missing: $archive" >&2
    echo "On a connected workstation, run template/prepare-offline.sh blackbox-exporter and copy the blackbox-exporter folder." >&2
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

ARCHIVE="$DIST_DIR/blackbox_exporter-${VERSION}.linux-amd64.tar.gz"
CURRENT_VERSION="$(/usr/local/bin/blackbox_exporter --version 2>/dev/null | head -1 || true)"
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

echo "== blackbox_exporter install =="

if ! id blackbox_exporter &>/dev/null; then
  run useradd --system --no-create-home --shell /usr/sbin/nologin blackbox_exporter
fi

if [[ "$CURRENT_VERSION" == *"$VERSION"* ]]; then
  echo "blackbox_exporter $VERSION already installed, skipping binary install"
else
  install_local_binary "$ARCHIVE" "blackbox_exporter-${VERSION}.linux-amd64" blackbox_exporter /usr/local/bin/blackbox_exporter
fi

run mkdir -p /etc/blackbox_exporter
run install -m 0644 "$SCRIPT_DIR/blackbox.yml" /etc/blackbox_exporter/blackbox.yml

run install -m 0644 "$SCRIPT_DIR/blackbox_exporter.service.tmpl" /etc/systemd/system/blackbox_exporter.service

run systemctl daemon-reload
run systemctl enable blackbox_exporter.service
run systemctl restart blackbox_exporter.service

echo "Done. Verify: curl 'localhost:9115/probe?target=<plc-ip>&module=icmp'"
