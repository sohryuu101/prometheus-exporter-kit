# Offline exporter packages

Each exporter directory is self-contained: its installer, service template, and
any exporter-specific configuration. Scrape jobs for Prometheus are separate —
see `prometheus-jobs/`.

## Layout

| Path | What it is |
| --- | --- |
| `node-exporter/`, `process-exporter/`, `mssql-exporter/`, `blackbox-exporter/` | Linux/amd64 packages, installed as systemd units |
| `windows-exporter/`, `blackbox-exporter-windows/`, `mssql-exporter-windows/`, `snmp-exporter-windows/` | Windows/amd64 kits, installed as NSSM services (`.zip`) |
| `ipmi-text/` | Script package: IPMI sensors into node_exporter's textfile collector |
| `snmp-exporter/` | Shared `snmp.yml` and the topology check tool |
| `switch-probe/` | Serial-console discovery scripts for switches |
| `prometheus-jobs/` | Renders the Prometheus scrape job YAML |
| `prepare-offline.sh` | Stages the upstream release archives |
| `package.sh` | Builds the transfer-ready archives |

## Staging and building a package

The release archives are **not** committed to this repository. Stage them first
on an internet-connected workstation:

```sh
./template/prepare-offline.sh all                                     # the four Linux packages
./template/prepare-offline.sh windows-exporter blackbox-exporter-windows \
                              mssql-exporter-windows snmp-exporter-windows
```

`OFFLINE_SOURCE_DIR=/path/to/archives` stages files you downloaded elsewhere
instead of fetching them. Each archive is checked against the upstream hash
committed in its package's `SHA256SUMS`; on a mismatch nothing is staged. When
you bump a version, take the new hash from the upstream release's checksum file,
not from a file you downloaded.

Then build the package:

```sh
./template/package.sh mssql-exporter      # or all, for the four Linux packages
```

Packages are site-independent and need no input (`mssql-exporter` asks for its
database addresses and SQL login on the server at install time). Output lands in
`template/out/`: `<package>.tar.gz` for Linux, `<package>.zip` for the Windows
kits, each with a `.sha256`. For process-exporter,
`EDIT_CONFIG=1 ./template/package.sh process-exporter` opens its `config.yml` in
`$EDITOR` before packaging.

Transfer the archive to the target host by whatever channel you have, then on
the server:

```sh
tar -xzf mssql-exporter.tar.gz && cd mssql-exporter
sudo bash install.sh --dry-run && sudo bash install.sh
```

Re-running `install.sh` restarts the exporter, so a version upgrade or changed
config takes effect immediately.

Each Linux package targets x86_64 (amd64). The server must already have Bash,
tar, `sha256sum`, core utilities, and systemd. The installer checks the archive
against the pinned upstream hash in the package's `SHA256SUMS` and does not
access the network or install OS packages.

Every installer asks for `PROMETHEUS_ALLOW`, the Prometheus server's IPs/CIDRs
(pre-set it in the environment to skip the prompt). On Linux it becomes a systemd
`IPAddressAllow` drop-in; on Windows, a firewall rule for the exporter's port.
Left empty, the port stays reachable by anyone and the installer warns. Each
package README explains the details and what is still exposed.

See the README inside each package for its exact steps. The process-exporter
package includes a baseline `config.yml`; review its process matching rules for
the target host before installing. The MSSQL exporter prompts for its SQL login
during installation, so no credential file needs to be copied to the server.

## Prometheus scrape job (separate step)

Scrape jobs are independent of installing an exporter. After it is installed,
render the job YAML for the site. For manual entry into Prometheus:

```sh
./template/prometheus-jobs/render-job.sh node       # or process / mssql / blackbox / windows
```

It prompts for `STATION_NAME`, `STATION_ID`, `SEGMENT`, `TARGET_IP_MAIN` and
`TARGET_IP_BACKUP` (blackbox: the probing host's IP and the PLC IPs instead),
prints the YAML, and saves it under `template/out/`.

Blackbox jobs are the exception to the main/backup pattern: a probe endpoint is a
monitored target rather than an exporter host, so its targets are always given
explicitly.

## SNMP communities

`snmp-exporter/snmp.yml` ships with **placeholder** community strings
(`REPLACE_WITH_COMMUNITY`, `REPLACE_WITH_READ_ONLY_COMMUNITY`). Set them to your
site's values before deploying, and keep real values out of version control —
this file is a natural place to leak network credentials. `site_main` and
`site_ro` carry the placeholders; the `public_v1` / `public_v2` auths use the
SNMP default community `public` and are kept as in the source config. SNMP v2c
sends the community in clear text, so restrict it on the switches to the probe
host's address.

## Switch probe reports

`switch-probe/*.py` dump a switch's full configuration, local users and SNMP
communities over the serial console. Both prompt for the login password (never
on the command line) and write their report owner-only (`0600`). Treat the
reports as credentials; `.gitignore` excludes their default names.
