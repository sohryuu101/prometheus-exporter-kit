#!/usr/bin/env bash
# Render the Prometheus scrape job (YAML) for one exporter at one site, to paste
# into Prometheus. Independent of installing the exporter: run it before or after.
#
# Usage: ./render-job.sh <node|process|mssql|blackbox|windows>
# Prompts for the station values and target IPs.
# Output is saved under $OUT_DIR (default template/out).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/../out}"
KIND="${1:-}"
case "$KIND" in node|process|mssql|blackbox|windows) ;; *)
  echo "Usage: $0 <node|process|mssql|blackbox|windows>" >&2; exit 2 ;; esac

VARS=(STATION_NAME STATION_ID SEGMENT TARGET_IP_MAIN)
[[ "$KIND" == blackbox ]] || VARS+=(TARGET_IP_BACKUP)
[[ "$KIND" == blackbox ]] && VARS+=(PROBE_TARGETS)

for var in "${VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    label="$var"; [[ "$var" == PROBE_TARGETS ]] && label="PROBE_TARGETS (comma-separated PLC IPs)"
    read -r -p "$label: " "$var"
  fi
  [[ -n "${!var}" ]] || { echo "$var cannot be empty." >&2; exit 1; }
  # Values are pasted into YAML and STATION_NAME into a file name: keep both safe.
  if [[ "${!var}" =~ [[:cntrl:]\"\'\`\$\\{}] ]]; then
    echo "$var contains a character that is not allowed (quotes, \$, {}, backslash or control)." >&2; exit 1
  fi
  if [[ "$var" == STATION_NAME && ! "${!var}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "STATION_NAME may only contain letters, digits, '.', '_' and '-'." >&2; exit 1
  fi
  export "$var"
done

PROBE_TARGET_LIST=""
if [[ "$KIND" == blackbox ]]; then
  IFS=',' read -r -a probe_ips <<< "$PROBE_TARGETS"
  for ip in "${probe_ips[@]}"; do
    ip="${ip//[[:space:]]/}"
    [[ -n "$ip" ]] && PROBE_TARGET_LIST+="      - $ip"$'\n'
  done
  PROBE_TARGET_LIST="${PROBE_TARGET_LIST%$'\n'}"
fi

content="$(cat "$SCRIPT_DIR/$KIND.yml.tmpl"; printf x)"
content="${content%x}"
for var in STATION_NAME STATION_ID SEGMENT TARGET_IP_MAIN TARGET_IP_BACKUP; do
  [[ -n "${!var+x}" ]] || continue
  pattern='${'"$var"'}'
  content=${content//"$pattern"/"${!var}"}
done
content=${content//'${PROBE_TARGET_LIST}'/"$PROBE_TARGET_LIST"}

mkdir -p "$OUT_DIR"
out="$OUT_DIR/$STATION_NAME-$KIND.job.yml"
printf '%s' "$content" > "$out"
echo
cat "$out"
echo
echo "Saved $out" >&2
