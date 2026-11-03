#!/usr/bin/env bash
# Install/refresh blackbox_exporter using files in this package directory.
#
# Usage: sudo ./install.sh [--dry-run]
# Optional: PROMETHEUS_ALLOW (scraper IPs/CIDRs) and PROBE_NETWORKS (probed CIDRs)
# restrict the exporter's network access; both are asked for when unset.

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
  # SHA256SUMS ships in the package and holds the pinned upstream hash.
  if [[ ! -r "$SCRIPT_DIR/SHA256SUMS" ]]; then
    echo "Pinned checksum file is missing: $SCRIPT_DIR/SHA256SUMS" >&2
    return 1
  fi
  (cd "$DIST_DIR" && sha256sum -c "$SCRIPT_DIR/SHA256SUMS")
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

# Restrict who can reach this exporter (it has no authentication of its own).
# PROMETHEUS_ALLOW: comma-separated IPs/CIDRs of the Prometheus server(s); asked
# for when unset and running in a terminal. Applied as a systemd drop-in with
# IPAddressDeny=any + IPAddressAllow, which filters ALL of the unit's traffic, so
# any address the exporter itself must reach is passed as extra arguments.
# Empty PROMETHEUS_ALLOW keeps an existing drop-in, or leaves the port open.
apply_ip_allow() {
  local unit="$1"; shift
  local dropin="/etc/systemd/system/$unit.d/10-ip-allow.conf"
  local allow="${PROMETHEUS_ALLOW:-}" addr list=""

  if [[ -z "$allow" && -t 0 ]]; then
    read -r -p "Prometheus server IP(s)/CIDR(s) allowed to scrape, comma-separated (empty = anyone): " allow
  fi
  allow="${allow//,/ }"
  if [[ -z "${allow// /}" ]]; then
    if [[ -f "$dropin" ]]; then
      echo "Keeping the existing scrape restriction in $dropin"
    else
      echo "WARNING: PROMETHEUS_ALLOW not set: $unit is reachable by anyone who can reach this host." >&2
    fi
    return 0
  fi

  local -a addrs
  read -r -a addrs <<< "$allow"
  for addr in "${addrs[@]}" "$@"; do
    if [[ ! "$addr" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
      echo "Not an IP address or CIDR: $addr" >&2
      exit 1
    fi
    list+=" $addr"
  done

  if $DRY_RUN; then
    printf '[dry-run] write %s: IPAddressDeny=any, IPAddressAllow=localhost%s\n' "$dropin" "$list"
  else
    mkdir -p "$(dirname "$dropin")"
    printf '[Service]\nIPAddressDeny=any\nIPAddressAllow=localhost%s\n' "$list" > "$dropin"
    chmod 0644 "$dropin"
    echo "Restricted $unit to localhost$list"
  fi

  # systemd only enforces this with eBPF on a cgroup v2 (unified or hybrid)
  # hierarchy, from v235. Elsewhere it is silently ignored: say so.
  local sd_version
  sd_version="$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ ! "$sd_version" =~ ^[0-9]+$ ]] || ((sd_version < 235)) ||
     { [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" != cgroup2fs ]] && [[ ! -d /sys/fs/cgroup/unified ]]; }; then
    echo "WARNING: this host's systemd cannot enforce IPAddressAllow (needs systemd >= 235 and cgroup v2)." >&2
    echo "         Restrict the port with the host firewall instead (firewalld/iptables)." >&2
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

# The IP restriction also filters the probes themselves, so it needs the networks
# the exporter probes (PROBE_NETWORKS, comma-separated CIDRs, e.g. the PLC
# segment). Without them a restriction would break every probe, so none is set.
if [[ -z "${PROBE_NETWORKS:-}" && -t 0 ]]; then
  read -r -p "Networks this host probes, comma-separated CIDRs (empty = do not restrict): " PROBE_NETWORKS
fi
read -r -a probe_networks <<< "${PROBE_NETWORKS//,/ }"
if ((${#probe_networks[@]})); then
  apply_ip_allow blackbox_exporter.service "${probe_networks[@]}"
else
  echo "WARNING: PROBE_NETWORKS not set, so :9115 is not restricted. Anyone who can reach it can" >&2
  echo "         make this host probe arbitrary addresses. Firewall it to the Prometheus server." >&2
fi

run systemctl daemon-reload
run systemctl enable blackbox_exporter.service
run systemctl restart blackbox_exporter.service

echo "Done. Verify: curl 'localhost:9115/probe?target=<plc-ip>&module=icmp'"
