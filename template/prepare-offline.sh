#!/usr/bin/env bash
# Stage release archives inside each standalone exporter package.
# Set OFFLINE_SOURCE_DIR to copy archives downloaded on another workstation.

set -euo pipefail

NODE_VERSION="1.11.1"
PROCESS_VERSION="0.8.7"
SQL_VERSION="0.24.0"
BLACKBOX_VERSION="0.28.0"
WINDOWS_EXPORTER_VERSION="0.25.1"
SNMP_VERSION="0.30.1"
NSSM_VERSION="2.24"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_SOURCE_DIR="${OFFLINE_SOURCE_DIR:-}"

usage() {
  echo "Usage: $0 [all|node-exporter|process-exporter|mssql-exporter|blackbox-exporter|windows-exporter|blackbox-exporter-windows|mssql-exporter-windows|snmp-exporter-windows ...]" >&2
  echo "  all = the four Linux packages; the Windows kits must be named explicitly." >&2
  exit 2
}

if [[ -z "$OFFLINE_SOURCE_DIR" ]] && ! command -v curl >/dev/null 2>&1; then
  echo "curl is required on the connected staging workstation (or set OFFLINE_SOURCE_DIR)." >&2
  exit 1
fi
if ! command -v tar >/dev/null 2>&1; then
  echo "tar is required on the staging workstation." >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "sha256sum or shasum is required to verify the downloads." >&2
  exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ssc-exporter-offline.XXXXXX")"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT

stage_exporter() {
  local package="$1"
  local archive="$2"
  local url="$3"
  local staging_dir="$STAGING_ROOT/$package"
  local dist_dir="$SCRIPT_DIR/$package/dist"

  mkdir -p "$staging_dir"
  if [[ -n "$OFFLINE_SOURCE_DIR" ]]; then
    if [[ ! -r "$OFFLINE_SOURCE_DIR/$archive" ]]; then
      echo "Archive not found in OFFLINE_SOURCE_DIR: $OFFLINE_SOURCE_DIR/$archive" >&2
      return 1
    fi
    cp "$OFFLINE_SOURCE_DIR/$archive" "$staging_dir/$archive"
  else
    curl --fail --location --silent --show-error --retry 3 \
      --output "$staging_dir/$archive" "$url"
  fi

  # Verify against the upstream hash committed in the package (SHA256SUMS), not a
  # hash computed from whatever was just downloaded: that would only prove the
  # file was copied intact, not that it is the genuine upstream release.
  if [[ ! -r "$SCRIPT_DIR/$package/SHA256SUMS" ]]; then
    echo "Missing $SCRIPT_DIR/$package/SHA256SUMS; cannot verify the download." >&2
    return 1
  fi
  cp "$SCRIPT_DIR/$package/SHA256SUMS" "$staging_dir/SHA256SUMS"
  if ! (cd "$staging_dir" && { sha256sum -c SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS; }); then
    echo "Checksum verification failed for $archive; nothing staged." >&2
    return 1
  fi

  if ! tar -tzf "$staging_dir/$archive" >/dev/null; then
    echo "Invalid gzip tar archive: $staging_dir/$archive" >&2
    return 1
  fi

  mkdir -p "$dist_dir"
  mv "$staging_dir/$archive" "$dist_dir/$archive"
  echo "Staged $package in $dist_dir"
}

# Fetch one archive into a directory, from OFFLINE_SOURCE_DIR when set.
fetch_archive() {
  local archive="$1"
  local url="$2"
  local dest_dir="$3"
  if [[ -n "$OFFLINE_SOURCE_DIR" ]]; then
    if [[ ! -r "$OFFLINE_SOURCE_DIR/$archive" ]]; then
      echo "Archive not found in OFFLINE_SOURCE_DIR: $OFFLINE_SOURCE_DIR/$archive" >&2
      return 1
    fi
    cp "$OFFLINE_SOURCE_DIR/$archive" "$dest_dir/$archive"
  else
    curl --fail --location --silent --show-error --retry 3 \
      --output "$dest_dir/$archive" "$url"
  fi
}

# The Windows kits are .zip packages and their binaries are not committed. Stage
# the upstream .exe files next to each kit's install.bat, then verify them
# against the SHA256SUMS already committed in the kit.
stage_windows_kit() {
  local package="$1"
  local dest_dir="$SCRIPT_DIR/$package"
  local staging_dir="$STAGING_ROOT/$package"
  local asset

  if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip is required to stage the Windows kits." >&2
    return 1
  fi
  if [[ ! -r "$dest_dir/SHA256SUMS" ]]; then
    echo "Missing $dest_dir/SHA256SUMS; cannot verify the download." >&2
    return 1
  fi

  mkdir -p "$staging_dir"

  case "$package" in
    windows-exporter)
      asset="windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.exe"
      fetch_archive "$asset" \
        "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/${asset}" \
        "$staging_dir"
      ;;
    blackbox-exporter-windows)
      asset="blackbox_exporter-${BLACKBOX_VERSION}.windows-amd64.zip"
      fetch_archive "$asset" \
        "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/${asset}" \
        "$staging_dir"
      unzip -j -o "$staging_dir/$asset" '*/blackbox_exporter.exe' -d "$staging_dir" >/dev/null
      rm -f "$staging_dir/$asset"
      ;;
    mssql-exporter-windows)
      # sql_exporter.exe is ~95 MB, so it is never committed: this is how it arrives.
      asset="sql_exporter-${SQL_VERSION}.windows-amd64.zip"
      fetch_archive "$asset" \
        "https://github.com/burningalchemist/sql_exporter/releases/download/${SQL_VERSION}/${asset}" \
        "$staging_dir"
      unzip -j -o "$staging_dir/$asset" '*/sql_exporter.exe' -d "$staging_dir" >/dev/null
      rm -f "$staging_dir/$asset"
      ;;
    snmp-exporter-windows)
      asset="snmp_exporter-${SNMP_VERSION}.windows-amd64.zip"
      fetch_archive "$asset" \
        "https://github.com/prometheus/snmp_exporter/releases/download/v${SNMP_VERSION}/${asset}" \
        "$staging_dir"
      unzip -j -o "$staging_dir/$asset" '*/snmp_exporter.exe' -d "$staging_dir" >/dev/null
      rm -f "$staging_dir/$asset"
      ;;
    *)
      echo "Unknown Windows kit: $package" >&2
      return 1
      ;;
  esac

  asset="nssm-${NSSM_VERSION}.zip"
  fetch_archive "$asset" "https://nssm.cc/release/${asset}" "$staging_dir"
  unzip -j -o "$staging_dir/$asset" '*/win64/nssm.exe' -d "$staging_dir" >/dev/null
  rm -f "$staging_dir/$asset"

  cp "$dest_dir/SHA256SUMS" "$staging_dir/SHA256SUMS"
  if ! (cd "$staging_dir" && { sha256sum -c SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS; }); then
    echo "Checksum verification failed for $package; nothing staged." >&2
    return 1
  fi

  mv "$staging_dir"/*.exe "$dest_dir/"
  echo "Staged $package in $dest_dir"
}

if (($# == 0)) || { (($# == 1)) && [[ "$1" == "all" ]]; }; then
  set -- node-exporter process-exporter mssql-exporter blackbox-exporter
elif [[ "$1" == "all" ]]; then
  usage
fi

for package in "$@"; do
  case "$package" in
    node-exporter)
      stage_exporter "$package" \
        "node_exporter-${NODE_VERSION}.linux-amd64.tar.gz" \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz"
      ;;
    process-exporter)
      stage_exporter "$package" \
        "process-exporter-${PROCESS_VERSION}.linux-amd64.tar.gz" \
        "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_VERSION}/process-exporter-${PROCESS_VERSION}.linux-amd64.tar.gz"
      ;;
    mssql-exporter)
      stage_exporter "$package" \
        "sql_exporter-${SQL_VERSION}.linux-amd64.tar.gz" \
        "https://github.com/burningalchemist/sql_exporter/releases/download/${SQL_VERSION}/sql_exporter-${SQL_VERSION}.linux-amd64.tar.gz"
      ;;
    blackbox-exporter)
      stage_exporter "$package" \
        "blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz" \
        "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz"
      ;;
    windows-exporter|blackbox-exporter-windows|mssql-exporter-windows|snmp-exporter-windows)
      stage_windows_kit "$package"
      ;;
    *) usage ;;
  esac
done
