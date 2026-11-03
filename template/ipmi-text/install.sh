#!/usr/bin/env bash
# Install/refresh the IPMI textfile collector (ipmi-text.sh) on a server.
#
# Usage: sudo ./install.sh [--dry-run] [--textfile-dir DIR]
#
# What it does (safe to re-run):
#   1. loads the ipmi_devintf and ipmi_si kernel modules and persists them
#   2. installs ipmi-text.sh to /opt/ipmi-text.sh (the previous copy is kept as .bak)
#   3. finds node_exporter's textfile directory (--textfile-dir overrides; falls
#      back to /var/lib/node_exporter/textfile, where the old script wrote)
#   4. makes root's crontab run it every minute, replacing any older ipmi-text.sh line
#   5. runs it once and shows the result
#
# Needs ipmitool already on the host (nothing is downloaded).

set -euo pipefail

INSTALL_PATH=/opt/ipmi-text.sh
DEFAULT_TEXTFILE_DIR=/var/lib/node_exporter/textfile
MODULES_CONF=/etc/modules-load.d/ipmi.conf
DRY_RUN=false

# textfile_dir_from_args: read process command lines on stdin, print the
# --collector.textfile.directory value of the first node_exporter (either
# "--flag=DIR" or "--flag DIR"), or nothing. Only a line whose program (first
# word) is node_exporter counts, not any command that mentions it.
textfile_dir_from_args() {
  grep -E '^[^ ]*node_exporter( |$)' \
    | sed -n 's/.*--collector\.textfile\.directory[= ]\([^ ]*\).*/\1/p' \
    | head -1 | tr -d "'\""
}

# merge_cron DIR: read a crontab on stdin, print it without any ipmi-text.sh
# line, plus the line that runs the collector every minute.
merge_cron() {
  local dir="$1"
  { grep -vF 'ipmi-text.sh' || true; } | sed '/./,$!d'
  printf '* * * * * IPMI_TEXTFILE_DIR=%s %s >/dev/null 2>&1\n' "$dir" "$INSTALL_PATH"
}

# detect_textfile_dir: print node_exporter's textfile directory, or nothing when
# no running node_exporter (or its systemd unit) names one.
detect_textfile_dir() {
  local dir
  dir="$(ps -eo args= 2>/dev/null | textfile_dir_from_args || true)"
  if [[ -z "$dir" ]] && command -v systemctl >/dev/null 2>&1; then
    local unit
    for unit in node_exporter node-exporter; do
      dir="$(systemctl cat "$unit" 2>/dev/null | textfile_dir_from_args || true)"
      [[ -z "$dir" ]] || break
    done
  fi
  printf '%s\n' "$dir"
}

# find_unit: print "UNIT FRAGMENT-FILE" for the systemd unit that runs node_exporter
# when its ExecStart is one plain line (so a flag can be appended), else nothing.
find_unit() {
  local pid unit frag
  command -v systemctl >/dev/null 2>&1 || return 0
  pid="$(pgrep -f '^[^ ]*node_exporter( |$)' 2>/dev/null | head -1 || true)"
  [[ -n "$pid" ]] || return 0
  unit="$(systemctl --no-pager status "$pid" 2>/dev/null | sed -n '1s/^[^A-Za-z0-9]*\([^ ]*\)\.service.*/\1/p')"
  [[ -n "$unit" ]] || return 0
  frag="$(systemctl show -p FragmentPath "$unit" 2>/dev/null | cut -d= -f2)"
  [[ -f "$frag" ]] || return 0
  [[ "$(grep -c '^ExecStart=' "$frag")" == 1 ]] || return 0
  ! grep -q '^ExecStart=.*\\$' "$frag" || return 0
  printf '%s %s\n' "$unit" "$frag"
}

# scrape_note SOURCE DIR [UNIT FRAGMENT]: SOURCE is "flag" (found on node_exporter),
# "override" (--textfile-dir) or "default" (nothing found). Reads process command
# lines on stdin. Prints a warning when node_exporter will not read DIR, with the
# commands that fix it when UNIT and its unit file FRAGMENT are known; else nothing.
scrape_note() {
  local source="$1" dir="$2" unit="${3:-}" frag="${4:-}" procs port
  [[ "$source" == default ]] || return 0
  procs="$(grep -E '^[^ ]*node_exporter( |$)' || true)"
  if [[ -n "$procs" ]]; then
    printf 'WARNING: node_exporter is running without --collector.textfile.directory, so it will not read %s/ipmi.prom.\n' "$dir"
    if [[ -n "$unit" && -n "$frag" ]]; then
      port="$(printf '%s\n' "$procs" | sed -n 's/.*--web\.listen-address[= ][^ ]*:\([0-9][0-9]*\).*/\1/p' | head -1)"
      printf '         To enable it, run as root (this restarts node_exporter: a few seconds without its metrics):\n\n'
      printf '  cp -p %s /root/%s.service.orig\n' "$frag" "$unit"
      printf "  sed -i '/^ExecStart=/ s|\$| --collector.textfile.directory=%s|' %s\n" "$dir" "$frag"
      printf '  systemctl daemon-reload && systemctl restart %s\n' "$unit"
      printf '  curl -s localhost:%s/metrics | grep -E %s\n\n' "${port:-9100}" "'^ipmi_(up|info\\{)'"
      printf '         To undo: cp -p /root/%s.service.orig %s && systemctl daemon-reload && systemctl restart %s\n' "$unit" "$frag" "$unit"
    else
      printf '         Add --collector.textfile.directory=%s to its start command and restart it,\n' "$dir"
      printf '         or, if it reads another directory, re-run with --textfile-dir DIR.\n'
    fi
  else
    printf 'WARNING: no node_exporter process found. ipmi.prom is written to %s, but nothing scrapes it\n' "$dir"
    printf '         until node_exporter runs with --collector.textfile.directory=%s.\n' "$dir"
  fi
}

run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

main() {
  local script_dir textfile_dir=""
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --textfile-dir) textfile_dir="${2:?--textfile-dir needs a directory}"; shift ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done

  if ! $DRY_RUN && [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root (ipmitool needs /dev/ipmi0)." >&2
    exit 1
  fi
  for command_name in ipmitool awk crontab install mktemp; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Required host command not found: $command_name" >&2
      exit 1
    fi
  done
  command -v timeout >/dev/null 2>&1 ||
    echo "Warning: no 'timeout' command; a hung ipmitool call will not be cut off." >&2

  local source=override
  if [[ -z "$textfile_dir" ]]; then
    textfile_dir="$(detect_textfile_dir)"
    source=flag
    if [[ -z "$textfile_dir" ]]; then textfile_dir="$DEFAULT_TEXTFILE_DIR"; source=default; fi
  fi
  echo "== IPMI textfile collector =="
  echo "textfile directory: $textfile_dir ($source)"

  # 1. kernel modules for /dev/ipmi0
  run modprobe ipmi_devintf || true
  run modprobe ipmi_si || true
  if ! $DRY_RUN; then
    if ! grep -qs '^ipmi_devintf$' "$MODULES_CONF" || ! grep -qs '^ipmi_si$' "$MODULES_CONF"; then
      mkdir -p "$(dirname "$MODULES_CONF")"
      printf 'ipmi_devintf\nipmi_si\n' > "$MODULES_CONF"
    fi
  else
    printf '[dry-run] write ipmi_devintf and ipmi_si to %s\n' "$MODULES_CONF"
  fi

  # 2. the script
  if [[ -f "$INSTALL_PATH" ]] && ! cmp -s "$script_dir/ipmi-text.sh" "$INSTALL_PATH"; then
    run cp -p "$INSTALL_PATH" "$INSTALL_PATH.bak"
  fi
  run install -m 0755 "$script_dir/ipmi-text.sh" "$INSTALL_PATH"
  run mkdir -p "$textfile_dir"

  # 3. cron, every minute
  local current merged
  current="$(crontab -l 2>/dev/null || true)"
  merged="$(printf '%s\n' "$current" | merge_cron "$textfile_dir")"
  if [[ "$merged" == "$current" ]]; then
    echo "crontab already runs $INSTALL_PATH every minute"
  elif $DRY_RUN; then
    printf '[dry-run] crontab line: %s\n' "$(printf '%s\n' "$merged" | grep -F 'ipmi-text.sh')"
  else
    printf '%s\n' "$merged" | crontab -
    echo "crontab updated"
  fi

  local note unit="" frag=""
  if [[ "$source" == default ]]; then
    read -r unit frag < <(find_unit) || true
  fi
  note="$(ps -eo args= 2>/dev/null | scrape_note "$source" "$textfile_dir" "$unit" "$frag")"

  # 4. first run
  if $DRY_RUN; then
    printf '[dry-run] IPMI_TEXTFILE_DIR=%s %s\n' "$textfile_dir" "$INSTALL_PATH"
    [[ -z "$note" ]] || printf '%s\n' "$note"
  else
    IPMI_TEXTFILE_DIR="$textfile_dir" "$INSTALL_PATH" || true
    if grep -qx 'ipmi_up 1' "$textfile_dir/ipmi.prom" 2>/dev/null; then
      grep -E '^(ipmi_up|ipmi_sel_critical_entries) |^ipmi_info[{]' "$textfile_dir/ipmi.prom" || true
      if [[ -n "$note" ]]; then
        printf '%s\n' "$note" >&2
        echo "Installed and collecting, but NOT yet visible in Prometheus (see the warning above)." >&2
      else
        echo "Done."
      fi
    else
      echo "Installed, but ipmitool did not answer (ipmi_up 0). Check /dev/ipmi0 and run: sudo ipmitool sdr elist" >&2
      exit 1
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
