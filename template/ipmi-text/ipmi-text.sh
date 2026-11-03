#!/bin/sh
# Write the server's IPMI data as a node_exporter textfile (ipmi.prom).
#
# Runs in-band as root (ipmitool on /dev/ipmi0); no BMC LAN, iDRAC, iLO or
# vendor agent is needed. POSIX sh + awk only, so it runs under mawk too.
#
# Environment (all optional):
#   IPMI_TEXTFILE_DIR  where ipmi.prom goes (default /var/lib/node_exporter/textfile)
#   IPMITOOL           the ipmitool binary (default ipmitool)
#   IPMI_TIMEOUT       seconds allowed per ipmitool call (default 10)
#
# Metrics:
#   ipmi_up                                 1 when `sdr elist` answered, else 0
#   ipmi_collect_success{command}           1 per ipmitool call that answered
#   ipmi_textfile_scrape_time_seconds       written only when ipmi_up is 1
#   ipmi_temperature_celsius, ipmi_temperature_threshold_celsius,
#   ipmi_fan_speed_rpm, ipmi_fan_speed_threshold_rpm   (unchanged, from `sensor`)
#   ipmi_sensor_status{sensor,id,entity,type}          0 ok, 1 nc, 2 cr, 3 nr
#   ipmi_sensor_value{sensor,id,entity,type,unit}      volts, amps, watts, percent, ...
#   ipmi_discrete_state{sensor,id,entity,type,state}   1 per asserted state
#   ipmi_sel_entries, ipmi_sel_free_bytes, ipmi_sel_critical_entries
#   ipmi_chassis_power_on, ipmi_info{manufacturer,model,serial,bmc_firmware}
#
# `type` is best effort (psu, power, cpu, memory, drive, fan, battery,
# temperature, bios, other), derived from the entity ID and the sensor name, so it
# works across vendors. Every sensor with a reading is exported either way.

set -u

DIR=${IPMI_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}
IPMITOOL=${IPMITOOL:-ipmitool}
IPMI_TIMEOUT=${IPMI_TIMEOUT:-10}
OUT="$DIR/ipmi.prom"
START=$(date +%s)

mkdir -p "$DIR" || exit 1

# One run at a time: the calls can take a while on a loaded BMC and cron fires
# every minute. The lock lives in a root-only directory, not in the textfile
# directory, which other accounts may be able to write to.
LOCK_PARENT=/run
[ -d "$LOCK_PARENT" ] || LOCK_PARENT=/var/run
LOCK="$LOCK_PARENT/ipmi-text.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  old=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ipmi-text.XXXXXX") || { rm -rf "$LOCK"; exit 1; }
trap 'rm -rf "$WORK" "$LOCK"' EXIT INT TERM

TIMEOUT_BIN=
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout; fi

# run NAME ipmitool-args... : output to $WORK/NAME, success flag to $WORK/NAME.ok
# (an answer is exit status 0 and some output).
run() {
  name=$1; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$IPMI_TIMEOUT" "$IPMITOOL" "$@" > "$WORK/$name" 2>/dev/null
  else
    "$IPMITOOL" "$@" > "$WORK/$name" 2>/dev/null
  fi
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$WORK/$name" ]; then echo 1 > "$WORK/$name.ok"; else echo 0 > "$WORK/$name.ok"; fi
}

ok() { [ "$(cat "$WORK/$1.ok" 2>/dev/null)" = 1 ]; }

run sensor sensor
run sdr sdr elist
run sel_info sel info
run sel_elist sel elist
run fru fru print 0
run mc_info mc info
run power power status

UP=0
if ok sdr; then UP=1; fi

PROM="$WORK/ipmi.prom"
: > "$PROM"

{
  printf '# HELP ipmi_up 1 when ipmitool answered `sdr elist`, 0 when it failed or /dev/ipmi0 is missing\n'
  printf '# TYPE ipmi_up gauge\n'
  printf 'ipmi_up %s\n' "$UP"
  printf '# HELP ipmi_collect_success 1 when the ipmitool call answered\n'
  printf '# TYPE ipmi_collect_success gauge\n'
  for c in sensor sdr sel_info sel_elist fru mc_info power; do
    if ok "$c"; then v=1; else v=0; fi
    printf 'ipmi_collect_success{command="%s"} %s\n' "$c" "$v"
  done
} >> "$PROM"

# ipmitool sensor columns:
# Name | reading | unit | status | lower-nonrecov | lower-crit | lower-noncrit | upper-noncrit | upper-crit | upper-nonrecov
if ok sensor; then
  awk -F'|' '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
BEGIN{
  print "# HELP ipmi_temperature_celsius Temperature reading from IPMI (degrees C)"
  print "# TYPE ipmi_temperature_celsius gauge"
  print "# HELP ipmi_temperature_threshold_celsius Temperature threshold from IPMI"
  print "# TYPE ipmi_temperature_threshold_celsius gauge"
  print "# HELP ipmi_fan_speed_rpm Fan speed reading from IPMI (RPM)"
  print "# TYPE ipmi_fan_speed_rpm gauge"
  print "# HELP ipmi_fan_speed_threshold_rpm Fan speed threshold from IPMI"
  print "# TYPE ipmi_fan_speed_threshold_rpm gauge"
  t=0; f=0
}
{
  name=esc(trim($1)); reading=trim($2); unit=trim($3); status=trim($4)
  lnrec=trim($5); lcrit=trim($6); lncrit=trim($7); uncrit=trim($8); ucrit=trim($9); unrec=trim($10)
  if (unit=="degrees C") {
    t++
    if (reading ~ /^[0-9.]+$/)
      printf "ipmi_temperature_celsius{sensor=\"%s\",id=\"%d\",status=\"%s\"} %s\n", name, t, status, reading
    if (ucrit  ~ /^[0-9.]+$/) printf "ipmi_temperature_threshold_celsius{sensor=\"%s\",id=\"%d\",level=\"upper_critical\"} %s\n", name, t, ucrit
    if (uncrit ~ /^[0-9.]+$/) printf "ipmi_temperature_threshold_celsius{sensor=\"%s\",id=\"%d\",level=\"upper_non_critical\"} %s\n", name, t, uncrit
    if (lcrit  ~ /^[0-9.]+$/) printf "ipmi_temperature_threshold_celsius{sensor=\"%s\",id=\"%d\",level=\"lower_critical\"} %s\n", name, t, lcrit
    if (lncrit ~ /^[0-9.]+$/) printf "ipmi_temperature_threshold_celsius{sensor=\"%s\",id=\"%d\",level=\"lower_non_critical\"} %s\n", name, t, lncrit
  } else if (unit=="RPM") {
    f++
    if (reading ~ /^[0-9.]+$/)
      printf "ipmi_fan_speed_rpm{sensor=\"%s\",id=\"%d\",status=\"%s\"} %s\n", name, f, status, reading
    if (lcrit ~ /^[0-9.]+$/) printf "ipmi_fan_speed_threshold_rpm{sensor=\"%s\",id=\"%d\",level=\"lower_critical\"} %s\n", name, f, lcrit
    if (ucrit ~ /^[0-9.]+$/) printf "ipmi_fan_speed_threshold_rpm{sensor=\"%s\",id=\"%d\",level=\"upper_critical\"} %s\n", name, f, ucrit
  }
}
' "$WORK/sensor" >> "$PROM"
fi

# ipmitool sdr elist columns: Name | sensor id | status | entity.instance | reading
# The reading is a number and unit ("216 Watts"), a discrete state ("Presence
# detected"), or empty. Sensors that say ns/na (no reading) are skipped.
if ok sdr; then
  awk -F'|' '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\001-\037]/,"",s); return s }
function classify(name, ent,    n, e, ln) {
  ln = tolower(name); e = ent; sub(/\..*$/, "", e)
  # Entity 34 is the BIOS: the Dell event-log sensors (ECC Corr Err, PCI System Err,
  # CPU Protocol Err ...) report decoded event bits, not a live state. Keep them
  # apart so alerts on cpu or memory do not pick them up.
  if (e == 34) return "bios"
  if (ln ~ /^(drive|hdd|disk)/ || e == 4 || e == 15 || e == 26) return "drive"
  if (ln ~ /battery/) return "battery"
  if (ln ~ /^(pwr|power) (consumption|usage)/ || ln ~ /power meter/ || ln ~ /system level/) return "power"
  if (e == 10 || e == 19 || e == 20 || ln ~ /^ps[ 0-9]/ || ln ~ /^psu/ || ln ~ /power supply/) return "psu"
  if (ln ~ /^fan/ || e == 29 || e == 30) return "fan"
  if (ln ~ /^(dimm|mem)/ || e == 8 || e == 32) return "memory"
  if (ln ~ /^(cpu|processor)/ || e == 3) return "cpu"
  if (ln ~ /temp/) return "temperature"
  return "other"
}
BEGIN {
  print "# HELP ipmi_sensor_status IPMI sensor status: 0 ok, 1 non-critical, 2 critical, 3 non-recoverable (sensors with no reading are left out)"
  print "# TYPE ipmi_sensor_status gauge"
  print "# HELP ipmi_sensor_value Numeric IPMI sensor reading in the unit label (temperatures and fan speeds are in their own metrics)"
  print "# TYPE ipmi_sensor_value gauge"
  print "# HELP ipmi_discrete_state 1 for each state a discrete IPMI sensor reports (for example Presence detected, Drive Present, Fully Redundant)"
  print "# TYPE ipmi_discrete_state gauge"
}
{
  if (NF < 5) next
  name = trim($1); id = trim($2); status = trim($3); ent = trim($4); reading = trim($5)
  if (name == "" || id == "") next
  if (status == "ok") sv = 0
  else if (status == "nc" || status == "lnc" || status == "unc") sv = 1
  else if (status == "cr" || status == "lcr" || status == "ucr") sv = 2
  else if (status == "nr" || status == "lnr" || status == "unr") sv = 3
  else next
  type = classify(name, ent)
  labels = "sensor=\"" esc(name) "\",id=\"" esc(id) "\",entity=\"" esc(ent) "\",type=\"" type "\""
  printf "ipmi_sensor_status{%s} %d\n", labels, sv
  if (reading == "" || reading == "No Reading" || reading == "Not Readable") next
  n = split(reading, p, " ")
  if (p[1] ~ /^-?[0-9]+(\.[0-9]+)?$/ && n >= 2) {
    unit = p[2]
    for (i = 3; i <= n; i++) unit = unit " " p[i]
    if (unit == "degrees C" || unit == "RPM") next
    unit = tolower(unit); gsub(/ /, "_", unit)
    printf "ipmi_sensor_value{%s,unit=\"%s\"} %s\n", labels, esc(unit), p[1]
  } else {
    m = split(reading, st, ", ")
    for (i = 1; i <= m; i++) {
      s = trim(st[i])
      if (s != "") printf "ipmi_discrete_state{%s,state=\"%s\"} 1\n", labels, esc(s)
    }
  }
}
' "$WORK/sdr" >> "$PROM"
fi

# ipmitool sel info: "Entries : 12", "Free Space : 15488 bytes ..."
if ok sel_info; then
  awk -F':' '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
trim($1) == "Entries" { e = trim($2); sub(/ .*/, "", e); if (e ~ /^[0-9]+$/) entries = e }
trim($1) == "Free Space" { f = trim($2); sub(/ .*/, "", f); if (f ~ /^[0-9]+$/) free = f }
END {
  if (entries != "") {
    print "# HELP ipmi_sel_entries Entries in the System Event Log"
    print "# TYPE ipmi_sel_entries gauge"
    print "ipmi_sel_entries " entries
  }
  if (free != "") {
    print "# HELP ipmi_sel_free_bytes Free space in the System Event Log"
    print "# TYPE ipmi_sel_free_bytes gauge"
    print "ipmi_sel_free_bytes " free
  }
}
' "$WORK/sel_info" >> "$PROM"
fi

# ipmitool sel elist: id | date | time | sensor | event | Asserted/Deasserted
# A critical entry is an asserted event whose sensor or event text says critical,
# fail, fault, non-recoverable, uncorrectable, AC lost, redundancy lost or
# predictive. A deasserted event (the recovery) is not counted, whichever column
# says so. A recovery can also be logged as an Asserted event of its own ("Fully
# Redundant"), which has no keyword and is not counted. No time window: BMC clocks
# are often wrong, and the count drops when the log is cleared.
if ok sel_elist; then
  awk -F'|' '
BEGIN { c = 0 }
NF >= 6 {
  text = tolower($4 " " $5); ev = tolower($5); dir = tolower($6)
  # Dell logs a recovery as "State Deasserted | Asserted": check the event text as well as the last column
  if (dir ~ /deasserted/ || ev ~ /deasserted/ || dir !~ /asserted/) next
  if (text ~ /critical|fail|fault|non-recoverable|uncorrectable|ac lost|redundancy lost|predictive/) c++
}
END {
  print "# HELP ipmi_sel_critical_entries Asserted critical entries currently in the System Event Log"
  print "# TYPE ipmi_sel_critical_entries gauge"
  print "ipmi_sel_critical_entries " c
}
' "$WORK/sel_elist" >> "$PROM"
fi

if ok power; then
  awk '
/Chassis Power is/ { on = ($NF == "on") ? 1 : 0; seen = 1 }
END {
  if (seen) {
    print "# HELP ipmi_chassis_power_on 1 when the chassis power is on"
    print "# TYPE ipmi_chassis_power_on gauge"
    print "ipmi_chassis_power_on " on
  }
}
' "$WORK/power" >> "$PROM"
fi

# Server identity: model and serial from FRU 0 (product, else board, else chassis
# fields), BMC firmware from `mc info`.
{
  if ok fru; then
    awk -F' : ' '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
{ k = trim($1); v = trim($2) }
k == "Product Manufacturer" { pm = v } k == "Board Mfg" { bm = v }
k == "Product Name" { pn = v }         k == "Board Product" { bn = v }
k == "Product Serial" { ps = v }       k == "Board Serial" { bs = v } k == "Chassis Serial" { cs = v }
END {
  m = pm; if (m == "") m = bm
  n = pn; if (n == "") n = bn
  s = ps; if (s == "") s = bs; if (s == "") s = cs
  print m "\t" n "\t" s
}
' "$WORK/fru"
  else
    printf '\t\t\n'
  fi
  if ok mc_info; then
    awk -F' : ' '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
trim($1) == "Firmware Revision" { print trim($2) }
' "$WORK/mc_info"
  fi
} | awk -F'\t' '
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\001-\037]/,"",s); return s }
NR == 1 { m = $1; n = $2; s = $3; next }
NR == 2 { fw = $0 }
END {
  if (m != "" || n != "" || s != "" || fw != "") {
    print "# HELP ipmi_info Server identity from the FRU and the BMC (value is always 1)"
    print "# TYPE ipmi_info gauge"
    printf "ipmi_info{manufacturer=\"%s\",model=\"%s\",serial=\"%s\",bmc_firmware=\"%s\"} 1\n", esc(m), esc(n), esc(s), esc(fw)
  }
}
' >> "$PROM"

END=$(date +%s)
{
  printf '# HELP ipmi_textfile_duration_seconds How long the last IPMI collection took\n'
  printf '# TYPE ipmi_textfile_duration_seconds gauge\n'
  printf 'ipmi_textfile_duration_seconds %s\n' "$((END - START))"
  if [ "$UP" -eq 1 ]; then
    printf '# HELP ipmi_textfile_scrape_time_seconds Last successful IPMI textfile scrape\n'
    printf '# TYPE ipmi_textfile_scrape_time_seconds gauge\n'
    printf 'ipmi_textfile_scrape_time_seconds %s\n' "$END"
  fi
} >> "$PROM"

chmod 0644 "$PROM"
# Unpredictable temporary name in the target directory, then an atomic rename.
TMP_OUT=$(mktemp "$DIR/.ipmi.prom.XXXXXX") || exit 1
if ! mv -f "$PROM" "$TMP_OUT" || ! mv -f "$TMP_OUT" "$OUT"; then
  rm -f "$TMP_OUT"
  exit 1
fi
