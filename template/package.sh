#!/usr/bin/env bash
# Build one transfer-ready package per exporter (single file to push through
# Bomgar). Run on the workstation after prepare-offline.sh.
#
# Usage: ./package.sh [all|node-exporter|process-exporter|mssql-exporter|blackbox-exporter|blackbox-exporter-windows|windows-exporter|mssql-exporter-windows|snmp-exporter-windows ...]
#   all = the four Linux packages. The Windows/NSSM kits (blackbox-exporter-windows,
#   windows-exporter, mssql-exporter-windows, snmp-exporter-windows) are built as
#   .zip and must be named explicitly.
#
# Packages are site-independent and need no input here. mssql-exporter asks for
# its database addresses and SQL login on the server at install time.
# Set EDIT_CONFIG=1 to review process-exporter's config.yml in $EDITOR first
# (the edit applies to that tarball only).
#
# The Prometheus scrape job is separate: see prometheus-jobs/render-job.sh.
#
# Output ($OUT_DIR, default template/out): <package>.tar.gz (or .zip) + .sha256
# On the server:  tar -xzf <package>.tar.gz && cd <package> && sudo bash install.sh
# (the MSSQL exporter asks for its addresses and SQL login there; never packaged)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"

is_windows() { [[ -f "$SCRIPT_DIR/$1/install.bat" ]]; }

if (($# == 0)) || [[ "$1" == "all" ]]; then
  set -- node-exporter process-exporter mssql-exporter blackbox-exporter
fi
for package in "$@"; do
  case "$package" in node-exporter|process-exporter|mssql-exporter|blackbox-exporter|blackbox-exporter-windows|windows-exporter|mssql-exporter-windows|snmp-exporter-windows) ;; *)
    echo "Unknown package: $package" >&2; exit 2 ;; esac
  if is_windows "$package"; then
    [[ -r "$SCRIPT_DIR/$package/nssm.exe" ]] && ls "$SCRIPT_DIR/$package/"*exporter*.exe >/dev/null 2>&1 ||
      { echo "$package is missing nssm.exe or its exporter .exe." >&2; exit 1; }
  elif ! ls "$SCRIPT_DIR/$package/dist/"*.tar.gz >/dev/null 2>&1; then
    echo "No archive staged for $package; run prepare-offline.sh $package first." >&2
    exit 1
  fi

  # The SNMP configs ship placeholders only; the Windows kit's install.ps1 injects
  # the real community strings at install time. Refuse to build if a real value
  # has crept back in.
  if [[ "$package" == snmp-exporter-windows ]]; then
    offenders="$(grep -E '^[[:space:]]+community:' "$SCRIPT_DIR/$package/snmp.yml" \
      | grep -vE 'community:[[:space:]]*(REPLACE_WITH_(READ_ONLY_)?COMMUNITY|public)[[:space:]]*$' || true)"
    if [[ -n "$offenders" ]]; then
      echo "$package/snmp.yml must not carry real community strings; found:" >&2
      echo "$offenders" >&2
      exit 1
    fi
  fi
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ssc-package.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
mkdir -p "$OUT_DIR"

for package in "$@"; do
  cp -R "$SCRIPT_DIR/$package" "$STAGE/$package"
  is_windows "$package" || chmod +x "$STAGE/$package/install.sh"

  if [[ "$package" == process-exporter && "${EDIT_CONFIG:-}" == 1 ]]; then
    "${EDITOR:-vi}" "$STAGE/$package/config.yml"
  fi

  if is_windows "$package"; then
    ext=zip
    # SHA256SUMS stays in the zip: install.bat checks the copied binaries with it.
    (cd "$STAGE" && rm -f "$OUT_DIR/$package.zip" && zip -qr -X "$OUT_DIR/$package.zip" "$package")
  else
    ext=tar.gz
    # COPYFILE_DISABLE stops macOS tar adding ._* AppleDouble files.
    COPYFILE_DISABLE=1 tar -czf "$OUT_DIR/$package.tar.gz" -C "$STAGE" "$package"
  fi
  (cd "$OUT_DIR" && { sha256sum "$package.$ext" 2>/dev/null || shasum -a 256 "$package.$ext"; } > "$package.$ext.sha256")
  echo "Built $OUT_DIR/$package.$ext"
done
