#!/usr/bin/env bash
# Install/refresh mssql_exporter (burningalchemist/sql_exporter) on this
# host using files in this package directory.
#
# Usage: sudo ./install.sh [--dry-run]
# The database addresses and SQL credentials are requested interactively (or
# pre-set TARGET_IP_MAIN / TARGET_IP_BACKUP in the environment); the password is
# not echoed to the terminal.

set -euo pipefail

VERSION="0.24.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"

require_local_archive() {
  local archive="$1"
  if [[ ! -r "$archive" ]]; then
    echo "Required offline archive is missing: $archive" >&2
    echo "On a connected workstation, run template/prepare-offline.sh mssql-exporter and copy the mssql-exporter folder." >&2
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

# Substitute ${VAR} placeholders from the environment (no envsubst needed).
render() {
  local content="$1" var pattern
  content="$(cat "$content"; printf x)"
  content="${content%x}"
  for var in TARGET_IP_MAIN TARGET_IP_BACKUP MSSQL_SA_USER MSSQL_SA_PASSWORD MSSQL_ENCRYPT MSSQL_TRUST_CERT; do
    [[ -n "${!var+x}" ]] || continue
    pattern='${'"$var"'}'
    content=${content//"$pattern"/"${!var}"}
  done
  printf '%s' "$content"
}

for command_name in tar install systemctl sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required host command not found: $command_name" >&2
    exit 1
  fi
done

ARCHIVE="$DIST_DIR/sql_exporter-${VERSION}.linux-amd64.tar.gz"
CURRENT_VERSION="$(/usr/local/bin/mssql_exporter --version 2>/dev/null | head -1 || true)"
if [[ "$CURRENT_VERSION" != *"$VERSION"* ]]; then
  require_local_archive "$ARCHIVE"
fi

if [[ ! -t 0 ]]; then
  echo "SQL credentials must be entered interactively; run ./install.sh from a terminal." >&2
  exit 1
fi
[[ -n "${TARGET_IP_MAIN:-}" ]] || read -r -p "MSSQL main address (IP[:port]): " TARGET_IP_MAIN
[[ -n "${TARGET_IP_BACKUP:-}" ]] || read -r -p "MSSQL backup address (IP[:port]): " TARGET_IP_BACKUP
: "${TARGET_IP_MAIN:?address cannot be empty}"
: "${TARGET_IP_BACKUP:?address cannot be empty}"
export TARGET_IP_MAIN TARGET_IP_BACKUP

# TLS for the SQL connection. encrypt=true keeps the login and query results off
# the wire in clear text. The certificate is not validated by default because
# most SQL Servers use a self-signed one; set MSSQL_TRUST_CERT=false once the
# server has a certificate this host trusts. MSSQL_ENCRYPT=disable is only for
# servers that cannot do TLS 1.2 (SQL Server 2008 without updates).
MSSQL_ENCRYPT="${MSSQL_ENCRYPT:-true}"
MSSQL_TRUST_CERT="${MSSQL_TRUST_CERT:-true}"
case "$MSSQL_ENCRYPT" in true|disable) ;; *)
  echo "MSSQL_ENCRYPT must be true or disable." >&2; exit 1 ;; esac
case "$MSSQL_TRUST_CERT" in true|false) ;; *)
  echo "MSSQL_TRUST_CERT must be true or false." >&2; exit 1 ;; esac
if [[ "$MSSQL_ENCRYPT" != true ]]; then
  echo "WARNING: MSSQL_ENCRYPT=disable sends the SQL login without TLS." >&2
elif [[ "$MSSQL_TRUST_CERT" == true ]]; then
  echo "NOTE: the SQL connection is encrypted, but the server certificate is NOT validated" >&2
  echo "      (TrustServerCertificate=true), so an active man-in-the-middle is not detected." >&2
  echo "      Once the server certificate (or its CA) is trusted on this host, re-run with" >&2
  echo "      MSSQL_TRUST_CERT=false." >&2
fi
export MSSQL_ENCRYPT MSSQL_TRUST_CERT

echo "Use a dedicated read-only monitoring login (VIEW SERVER STATE), not sa."
read -r -p "MSSQL username: " MSSQL_SA_USER
read -r -s -p "MSSQL password: " MSSQL_SA_PASSWORD
printf '\n'
: "${MSSQL_SA_USER:?MSSQL username cannot be empty}"
: "${MSSQL_SA_PASSWORD:?MSSQL password cannot be empty}"

uri_encode() {
  local value="$1"
  local encoded="" char hex i
  local LC_ALL=C

  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9._~-]) encoded+="$char" ;;
      *)
        printf -v hex '%%%02X' "'$char"
        encoded+="$hex"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# These values are inserted into sqlserver:// URLs in config.yml.tmpl.
MSSQL_SA_USER="$(uri_encode "$MSSQL_SA_USER")"
MSSQL_SA_PASSWORD="$(uri_encode "$MSSQL_SA_PASSWORD")"
export MSSQL_SA_USER MSSQL_SA_PASSWORD

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

echo "== mssql_exporter install =="

if ! id mssql_exporter &>/dev/null; then
  run useradd --system --no-create-home --shell /usr/sbin/nologin mssql_exporter
fi

if [[ "$CURRENT_VERSION" == *"$VERSION"* ]]; then
  echo "mssql_exporter $VERSION already installed, skipping binary install"
else
  install_local_binary "$ARCHIVE" "sql_exporter-${VERSION}.linux-amd64" sql_exporter /usr/local/bin/mssql_exporter
fi

run mkdir -p /etc/mssql_exporter

if $DRY_RUN; then
  echo "[dry-run] would render $SCRIPT_DIR/config.yml.tmpl -> /etc/mssql_exporter/config.yml.tmpl"
else
  install -m 0640 -o mssql_exporter -g mssql_exporter "$SCRIPT_DIR/config.yml.tmpl" /etc/mssql_exporter/config.yml.tmpl
fi

# Render the credentials into the service config with owner-only permissions.
RENDERED_CONFIG="/etc/mssql_exporter/config.yml"
if $DRY_RUN; then
  echo "[dry-run] would render $SCRIPT_DIR/config.yml.tmpl -> $RENDERED_CONFIG (mode 0600)"
else
  (
    umask 077
    install -m 0600 -o mssql_exporter -g mssql_exporter /dev/null "$RENDERED_CONFIG"
    render "$SCRIPT_DIR/config.yml.tmpl" > "$RENDERED_CONFIG"
  )
fi
unset MSSQL_SA_USER MSSQL_SA_PASSWORD

if $DRY_RUN; then
  echo "[dry-run] would render $SCRIPT_DIR/mssql_exporter.service.tmpl -> /etc/systemd/system/mssql_exporter.service"
else
  render "$SCRIPT_DIR/mssql_exporter.service.tmpl" > /etc/systemd/system/mssql_exporter.service
fi
# The exporter must also reach both databases: allow them too (port stripped).
apply_ip_allow mssql_exporter.service "${TARGET_IP_MAIN%%:*}" "${TARGET_IP_BACKUP%%:*}"

run systemctl daemon-reload
run systemctl enable mssql_exporter.service
run systemctl restart mssql_exporter.service

echo "Done."
