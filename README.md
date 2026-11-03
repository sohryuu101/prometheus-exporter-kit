# prometheus-exporter-kit

Offline-installable Prometheus exporters for hosts that have no package manager
access, no build tools, and often no direct network path. Each exporter is a
self-contained directory you build into a single transferable archive, move to
the target host by whatever channel you have, and install from there.

Covers Linux (systemd) and Windows (NSSM service) hosts, plus IPMI sensor
collection, a shared SNMP topology config, and a renderer for the Prometheus
scrape jobs.

## Quick start

```sh
# 1. stage the upstream release archives (internet-connected workstation)
./template/prepare-offline.sh all
./template/prepare-offline.sh windows-exporter blackbox-exporter-windows \
                              mssql-exporter-windows snmp-exporter-windows

# 2. build the transferable archive
./template/package.sh node-exporter          # or all, for the four Linux packages

# 3. move template/out/node-exporter.tar.gz to the host, then there:
tar -xzf node-exporter.tar.gz && cd node-exporter
sudo bash install.sh --dry-run && sudo bash install.sh

# 4. render the Prometheus scrape job for the site
./template/prometheus-jobs/render-job.sh node
```

**Windows host, ready-made:** each Windows kit is attached, binaries included
and verified, to the [latest release](https://github.com/sohryuu101/prometheus-exporter-kit/releases/latest).
In a browser on the PC, download the one you need, for example
`https://github.com/sohryuu101/prometheus-exporter-kit/releases/latest/download/mssql-exporter-windows.zip`
(also `windows-exporter.zip`, `blackbox-exporter-windows.zip`,
`snmp-exporter-windows.zip`; each has a `.sha256` beside it). Extract it, then
right-click `install.bat` → Run as administrator. No git or bash needed.

**Windows host, built yourself:** build the kit's zip instead
(`./template/package.sh mssql-exporter-windows`), extract it on the PC and run
`install.bat` as Administrator. Or, if the PC has internet access, stage it on
the PC itself (no bash needed) and install in place:
`template\prepare-offline.cmd mssql-exporter-windows`, then
`template\mssql-exporter-windows\install.bat` as Administrator. It asks for the Prometheus server's address (for
the firewall rule) and any credentials the kit needs. Ports: `windows_exporter`
9182, `blackbox_exporter` 9115, `mssql_exporter` 9399, `snmp_exporter` 9116.

The release archives and the Windows `.exe` files are **not** committed — step 1
fetches them from their upstream releases and verifies each checksum.

## What is in here

| Path | What it is |
| --- | --- |
| `template/node-exporter/` | Host metrics (CPU, memory, disk, network, filesystem) |
| `template/process-exporter/` | Per-process metrics, matched by command line |
| `template/mssql-exporter/` | SQL Server metrics; prompts for its DSN and login at install |
| `template/blackbox-exporter/` | Probes for reachability of hosts and PLCs (ICMP/TCP/HTTP) |
| `template/windows-exporter/` | Windows/amd64 kit, installed as an NSSM service |
| `template/blackbox-exporter-windows/` | Windows/amd64 blackbox kit, plus remote-deploy scripts |
| `template/mssql-exporter-windows/` | Windows/amd64 SQL Server kit; prompts for its addresses and login at install |
| `template/snmp-exporter-windows/` | Windows/amd64 SNMP probe kit; prompts for the switch communities at install |
| `template/ipmi-text/` | IPMI sensors, PSUs, drive slots and SEL into node_exporter's textfile collector |
| `template/snmp-exporter/` | Shared `snmp.yml` and `topology_check.py` for switch topology data |
| `template/switch-probe/` | Serial-console discovery scripts for H3C and Huawei switches |
| `template/prometheus-jobs/` | Renders the scrape job YAML for a site |
| `template/prepare-offline.sh` | Stages upstream release archives |
| `template/package.sh` | Builds the transferable archives |

Full details, per-package steps, and the Prometheus job options are in
[`template/README.md`](template/README.md).

## Requirements

**Workstation (build):** Bash, `curl`, `tar`, `zip`, `unzip`, and `sha256sum` or
`shasum`. On macOS these are present except `sha256sum`, which the scripts fall
back from automatically.

**Linux target host:** Bash, `tar`, `sha256sum`, core utilities, and systemd. The
installer verifies the archive checksum and installs offline — it does not reach
the network or install OS packages.

**Windows target host:** Administrator rights. The kit installs the exporter as
an auto-start service and needs nothing else.

## Before you deploy: read the credentials note

`template/snmp-exporter/snmp.yml` ships with **placeholder** SNMP community
strings. Set them to your site's values before deploying, and keep real values
out of version control — this file is the natural place to leak network
credentials. See [`template/README.md`](template/README.md#snmp-communities).

The exporters have no authentication of their own. Every installer asks for
the Prometheus server's address (`PROMETHEUS_ALLOW`) and restricts the port to it:
a systemd `IPAddressAllow` drop-in on Linux, a firewall rule on Windows. Leave it
empty and the port stays open, with a warning. The Windows kits lock their
install folder to SYSTEM and Administrators and verify each binary's hash before
installing the service. Each package README says what is still exposed; read
them before putting a host on an untrusted network.

## Licenses

The bundled and downloaded binaries are unmodified upstream releases:
Prometheus `node_exporter`, `blackbox_exporter`, `snmp_exporter` and
`windows_exporter` (Apache-2.0), `process-exporter` (MIT),
`sql_exporter` (MIT), NSSM (public domain), and `ipmitool` (BSD).
Their `LICENSE` and `NOTICE` files are included alongside each package.
