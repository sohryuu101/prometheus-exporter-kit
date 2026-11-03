# SNMP exporter Windows package (NSSM)

Windows/amd64 kit for `snmp_exporter` v0.30.1, installed as a Windows service
(`snmp_exporter`, `C:\SnmpExporter`, auto-start, port 9116) using NSSM. The same
package works on every probe host; the scrape targets live in the Prometheus job,
not here. `snmp.yml` is the same file as `../snmp-exporter/snmp.yml`, so module
definitions are interchangeable with a Linux probe host on the same version.

## Contents
- `snmp_exporter.exe` — v0.30.1 windows-amd64, identical to the upstream release
  (not committed; `prepare-offline.sh` stages it)
- `snmp.yml` — the source config unchanged except that the two site community
  strings are **placeholders** (`public_v1`/`public_v2` keep `public`)
- `install.ps1` — prompts for the communities, renders `snmp.yml`, locks it down
- `install.bat` / `uninstall.bat` — run as Administrator
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc)
- `SHA256SUMS` — upstream hashes of both executables

## Flow
1. Stage the binaries: `./template/prepare-offline.sh snmp-exporter-windows`
   (verifies each against `SHA256SUMS`; a mismatch stages nothing).
2. Build the zip: `./template/package.sh snmp-exporter-windows`. It refuses to
   build if `snmp.yml` carries any community other than the placeholders or `public`.
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator. It asks for the Prometheus
   server's IPs/CIDRs (`PROMETHEUS_ALLOW`), then the read-only (`site_ro`) and
   main (`site_main`) communities, which are not echoed. Set `SNMP_COMMUNITY_RO` /
   `SNMP_COMMUNITY` in the environment to skip those prompts when scripting.
5. Verify: `http://localhost:9116/`, then a real walk, for example
   `http://localhost:9116/snmp?target=<switch-ip>&module=if_mib_lite&auth=site_main`
6. Prometheus job: the topology job is written by hand from
   `../snmp-exporter/job-topology.yml.example`. `render-job.sh` does not cover SNMP.

Re-run `install.bat` to change the communities; it prompts again.

## What the installer protects

- **Credentials.** The kit and the zip carry only placeholders
  (`REPLACE_WITH_COMMUNITY`, `REPLACE_WITH_READ_ONLY_COMMUNITY`). `install.ps1`
  writes the real values into `C:\SnmpExporter\snmp.yml` as quoted YAML strings,
  creates the file fresh (`CreateNew`, so a planted link fails the install) and
  restricts it to SYSTEM (read) and Administrators (full).
- **Install folder.** A junction/symlink at `C:\SnmpExporter` is refused. The
  folder is restricted to SYSTEM and Administrators (by SID) and the ACL re-read
  *before* anything is written, so a low-privilege user can neither read the
  communities nor replace `snmp_exporter.exe` (which runs as LocalSystem).
- **Binaries.** `install.bat` hashes the copies inside the locked folder against
  `SHA256SUMS` and aborts on a mismatch, before the service is installed.
- **Network access.** `/snmp` accepts any `target`, `module` and `auth`, so
  anyone who reaches port 9116 could make this host walk arbitrary devices with
  your communities. With `PROMETHEUS_ALLOW` set, `install.bat` adds the inbound
  firewall rule `snmp_exporter (Prometheus only)` for 9116 from those addresses.
  Empty keeps a rule from an earlier install, or leaves the port open with a
  warning. `uninstall.bat` removes the rule.

## What is still exposed

- The firewall rule only matters while Windows Firewall is on (the OFF check
  matches the English word, so it can miss on a localized Windows).
- SNMP v2c sends the community in clear text on the switch network. Restrict it
  on the switches to this host's address.
- No TLS or basic auth on the exporter endpoint (`--web.config.file` if needed).
- `uninstall.bat` leaves `snmp.yml` (with the communities) in place — delete it
  when decommissioning the host.

## Keeping snmp.yml in sync

This kit's `snmp.yml` must stay identical to `../snmp-exporter/snmp.yml`, which
also ships placeholders. When the shared config changes:

```sh
cp template/snmp-exporter/snmp.yml template/snmp-exporter-windows/snmp.yml
cmp template/snmp-exporter/snmp.yml template/snmp-exporter-windows/snmp.yml
```

`snmp-topology-huawei.yml` is deliberately **not** included: both of its modules
(`lldp_mib`, `huawei_entity_extent_mib`) are already defined in `snmp.yml`, and
loading both makes snmp_exporter refuse to start on the duplicate module.
