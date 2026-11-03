# Blackbox exporter Windows package (NSSM)

Windows/amd64 counterpart of `../blackbox-exporter`. Installs `blackbox_exporter`
v0.28.0 as a Windows service (`blackbox_exporter`, `C:\BlackboxExporter`,
auto-start, port 9115) using NSSM. PLC targets live only in the Prometheus scrape
job (`template/prometheus-jobs/render-job.sh blackbox`).

## Contents
- `blackbox_exporter.exe` — v0.28.0 windows-amd64 (identical to the upstream release; not committed, stage it)
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc); hashes in `SHA256SUMS`
- `blackbox.yml` — default modules, `icmp` used for reachability
- `install.bat` / `uninstall.bat` — run as Administrator
- `deploy_remote.ps1` / `deploy_remote_uninstall.ps1` — push to many PCs over WinRM/SMB

## Flow
1. Stage the binaries (downloads the upstream .exe and NSSM, verifies both against
   `SHA256SUMS`): `./template/prepare-offline.sh blackbox-exporter-windows`
2. Build the zip: `./template/package.sh blackbox-exporter-windows` (no prompts).
   Output in `template/out/`: `blackbox-exporter-windows.zip` (+ `.sha256`).
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator.
5. Verify: `http://localhost:9115`, then
   `http://<pc-ip>:9115/probe?target=<plc-ip>&module=icmp`.
5. Run `template/prometheus-jobs/render-job.sh blackbox` (asks for the PLC IPs; use
   this PC's IP as the main address) and paste the YAML into Prometheus.

## Security risk (known, accepted for now)
The exporter listens on all interfaces and `/probe` accepts any `target` and
`module`, so anyone who can reach port 9115 can make this PC probe arbitrary
hosts, including the PLC/OT segment. `blackbox.yml` also ships modules the scrape
job never uses (`http_post_2xx`, `tcp_connect`, `http_2xx_tls_skip`,
`irc_banner`, `ssh_banner*`, `grpc*`, `postgresql`, `http_3xx`).
Mitigations to apply when ready: trim `blackbox.yml` to `icmp` (and `tcp_connect`
if needed), allow inbound 9115 only from the Prometheus server in Windows
Firewall, optionally add `--web.config.file` basic auth/TLS.

### Install-path permissions (known, accepted for now)
- `install.bat` installs to `C:\BlackboxExporter` with default permissions. On a
  default Windows setup, folders created under `C:\` let any authenticated user
  write to them, and the service runs as LocalSystem. A low-privilege user on the
  PC could replace `blackbox_exporter.exe` and have it run as SYSTEM at the next
  restart. Mitigation when ready: `icacls C:\BlackboxExporter /inheritance:r /grant
  SYSTEM:(OI)(CI)F Administrators:(OI)(CI)F`.
- `deploy_remote.ps1` stages the kit in `C:\BlackboxExporterKit` (same default
  permissions) and runs `install.bat` from there as admin, so the staged files can
  be tampered with first. Mitigation when ready: stage under `C:\Windows\Temp` with a
  locked-down ACL and delete it afterwards, or skip remote deploy and use Bomgar.
- Neither matters if only administrators can log on to these PCs.

