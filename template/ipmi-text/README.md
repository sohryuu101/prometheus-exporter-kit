# server-inlet: IPMI textfile collector

Reads the server's own BMC in-band (`ipmitool` on `/dev/ipmi0`), so no iDRAC, iLO or IPMI LAN is needed, and
writes `ipmi.prom` for node_exporter's textfile collector. It runs every minute from root's crontab.
POSIX `sh` and `awk` only; it works on Dell, HPE, Lenovo and Supermicro because it selects by IPMI sensor
data, not by vendor sensor names.

## Install

```sh
./template/package.sh server-inlet          # on the workstation; push template/out/server-inlet.tar.gz
tar -xzf server-inlet.tar.gz && cd server-inlet
sudo bash install.sh --dry-run && sudo bash install.sh
```

`ipmitool` must already be on the server. The installer loads and persists the `ipmi_devintf` and `ipmi_si`
modules, installs `/opt/ipmi-text.sh` (a changed copy is kept as `.bak`), replaces any old `ipmi-text.sh`
line in root's crontab with one that runs it every minute, and runs it once. It writes to the directory
the running node_exporter reads (`--collector.textfile.directory`), else `/var/lib/node_exporter/textfile`,
where the old script wrote. Force one with `--textfile-dir DIR`.

`ipmitool` needs root: `/dev/ipmi0` is `root:root 0600`, and ipmitool prints "No such file" when a normal
user cannot open it. Use `sudo ipmitool sdr elist` to look by hand.

### Installing ipmitool when the RPM reports a missing dependency (RHEL/CentOS 7)

If `rpm -ivh ipmitool-*.rpm` fails with `Failed dependencies: OpenIPMI-modalias is needed by ipmitool`, bypass
it. `OpenIPMI-modalias` only provides module auto-load aliases, and `install.sh` already loads and persists
`ipmi_devintf` and `ipmi_si` itself, so ipmitool alone is enough:

```sh
sudo rpm -ivh --nodeps ipmitool-1.8.15-7.el7.x86_64.rpm
```

`--nodeps` ignores every missing dependency, not just that one, so check nothing else is missing:

```sh
ldd "$(command -v ipmitool)" | grep 'not found'     # no output means fine
sudo ipmitool sdr elist | head                      # needs /dev/ipmi0, so a BMC and root
```

Then run `sudo bash install.sh`.

## Metrics

| Metric | Meaning |
|---|---|
| `ipmi_up` | 1 when `sdr elist` answered; 0 when it failed or there is no `/dev/ipmi0` (a VM, modules not loaded). A failed run drops every sensor series instead of leaving stale ones |
| `ipmi_collect_success{command}` | 1 per ipmitool call that answered (`sensor`, `sdr`, `sel_info`, `sel_elist`, `fru`, `mc_info`, `power`) |
| `ipmi_textfile_scrape_time_seconds` | Written only when `ipmi_up` is 1 |
| `ipmi_textfile_duration_seconds` | How long the run took |
| `ipmi_temperature_celsius`, `ipmi_temperature_threshold_celsius`, `ipmi_fan_speed_rpm`, `ipmi_fan_speed_threshold_rpm` | Unchanged names and labels (inlet and exhaust temperature are `sensor="Inlet Temp"` and `"Exhaust Temp"` on Dell) |
| `ipmi_sensor_status{sensor,id,entity,type}` | 0 ok, 1 non-critical, 2 critical, 3 non-recoverable. Sensors that say `ns` (no reading) are left out |
| `ipmi_sensor_value{sensor,id,entity,type,unit}` | Numeric readings that are not temperature or fan speed: volts, amps, watts, percent |
| `ipmi_discrete_state{sensor,id,entity,type,state}` | 1 per state a discrete sensor reports: `Presence detected`, `Drive Present`, `Fully Redundant`, `State Deasserted` ... |
| `ipmi_sel_entries`, `ipmi_sel_free_bytes` | From `sel info` |
| `ipmi_sel_critical_entries` | Asserted SEL events whose sensor or event text says critical, fail, fault, non-recoverable, uncorrectable, AC lost, redundancy lost or predictive. A recovery is not counted, however the BMC logs it (`State Deasserted | Asserted`, `Fully Redundant | Asserted`). No time window (BMC clocks are often wrong); it drops when the log is cleared |
| `ipmi_chassis_power_on` | 1 when the chassis power is on |
| `ipmi_info{manufacturer,model,serial,bmc_firmware}` | Always 1; from FRU 0 and `mc info` |

`type` is best effort, from the entity ID and the sensor name: `psu`, `power`, `cpu`, `memory`, `drive`,
`fan`, `battery`, `temperature`, `bios`, `other`. Entity 34 (the BIOS) is always `bios`: the Dell event-log
sensors there (`ECC Corr Err`, `PCI System Err`, `CPU Protocol Err` ...) report decoded event bits such as
`EISA failsafe timeout` or `Transition to OK`, not a live state, so do not alert on their discrete states
(their `ipmi_sensor_status` is fine). A sensor is exported whatever its type. `sensor` plus `id` plus
`entity` is unique on a host; names alone repeat (Dell has several `Status` and `Presence` sensors).

Cardinality on a PowerEdge R450 is about 290 series per host.

### Alert ideas

```promql
ipmi_up == 0                                       # no IPMI data (also a VM: filter by job)
ipmi_sensor_status > 0                             # any sensor not ok
ipmi_discrete_state{type="psu",state!~"Presence detected|Present|Fully Redundant|State Deasserted"}
ipmi_discrete_state{type="drive",state!="Drive Present"}
increase(ipmi_sel_critical_entries[1h]) > 0
```

Note that `PS1 PG FAIL`-style sensors report `State Deasserted` when healthy.

## What it does not cover

- **Disk health.** IPMI gives slot presence and fault on a drive slot (`Drive 0: Drive Present`), not SMART
  or RAID state. Real disk health needs `smartctl` or the RAID CLI (`perccli`, `storcli`, `ssacli`); not done yet.
- **Chassis intrusion** is not exported (`Intrusion` status is still in `ipmi_sensor_status`).

## Tests

```sh
bash template/server-inlet/tests/run.sh
```

Runs the script against `tests/fixtures/<vendor>/` with a stub `ipmitool`. Only the Dell R450 `sdr elist`
is a real capture; the rest are synthetic (see `tests/fixtures/README.md`). To add a vendor, capture
`sensor`, `sdr elist`, `sel info`, `sel elist`, `fru print 0`, `mc info` and `power status` from a server
and add a matching block to `run.sh`.
