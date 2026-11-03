# Blackbox exporter Windows package (NSSM)

Windows/amd64 counterpart of `../blackbox-exporter`. Installs `blackbox_exporter`
v0.28.0 as a Windows service (`blackbox_exporter`, `C:\BlackboxExporter`,
auto-start, port 9115) using NSSM. PLC targets live only in the Prometheus scrape
job (`template/prometheus-jobs/render-job.sh blackbox`).

## Contents
- `blackbox_exporter.exe` — v0.28.0 windows-amd64 (identical to the upstream release; not committed, stage it)
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc); hashes in `SHA256SUMS`
- `blackbox.yml` — `icmp` (reachability), `tcp_connect`, `http_2xx` and `http_2xx_tls_skip`
- `install.bat` / `uninstall.bat` — run as Administrator
- `deploy_remote.ps1` / `deploy_remote_uninstall.ps1` — push to many PCs over WinRM (PSSession)

## Flow
1. Stage the binaries (downloads the upstream .exe and NSSM, verifies both against
   `SHA256SUMS`): `./template/prepare-offline.sh blackbox-exporter-windows`
2. Build the zip: `./template/package.sh blackbox-exporter-windows` (no prompts).
   Output in `template/out/`: `blackbox-exporter-windows.zip` (+ `.sha256`).
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator (set `PROMETHEUS_ALLOW` first for unattended runs, or answer the prompt).
5. Verify: `http://localhost:9115`, then
   `http://<pc-ip>:9115/probe?target=<plc-ip>&module=icmp`.
5. Run `template/prometheus-jobs/render-job.sh blackbox` (asks for the PLC IPs; use
   this PC's IP as the main address) and paste the YAML into Prometheus.

## Security notes
What the kit now does:
- **Install folder is locked down.** `install.bat` creates `C:\BlackboxExporter`, sets
  the owner to Administrators, runs `icacls /reset`, and grants only SYSTEM
  (`S-1-5-18`) and Administrators (`S-1-5-32-544`), before any file is copied in. A
  PowerShell check confirms only those SIDs are in the ACL; otherwise the install aborts.
- **Binaries are verified on the target.** After the copy into the locked folder,
  `blackbox_exporter.exe` and `nssm.exe` are hashed with Get-FileHash and compared with
  `SHA256SUMS` (shipped in the zip; install fails if it is missing). Mismatch or missing
  entry aborts before the service is installed or started.
- **Firewall restriction.** Set `PROMETHEUS_ALLOW` (comma-separated IPs/CIDRs of the
  Prometheus server[s], no spaces) or answer the prompt. Rule
  `blackbox_exporter (Prometheus only)` allows inbound TCP 9115 from those addresses only.
  Empty (also the case when run without a console) leaves the port open and prints a
  WARNING. `uninstall.bat` and `deploy_remote_uninstall.ps1` delete the rule.
- **Fewer modules.** `blackbox.yml` has `icmp` (used by the Prometheus job),
  `tcp_connect`, `http_2xx` and `http_2xx_tls_skip` (HTTPS with a self-signed
  certificate); the unused gRPC, SSH, IRC, POST and similar modules are removed.
- **Safer remote deploy.** `deploy_remote.ps1 -Targets ... -PrometheusAllow ...` opens a
  PSSession, creates a unique folder under `%WINDIR%\Temp` locked to SYSTEM and
  Administrators, copies the kit with `Copy-Item -ToSession`, runs `install.bat` there with
  `PROMETHEUS_ALLOW` set, and deletes the folder in a `finally` block. No SMB share or
  `C:\BlackboxExporterKit` anymore.

Remaining risks:
- The firewall rule only works while Windows Firewall is on. The installer warns if a
  profile is OFF (it looks for the English word `OFF`, so it may miss that on localized
  Windows). Other allow rules or group policy can still open 9115.
- With `PROMETHEUS_ALLOW` empty, anyone who can reach 9115 can make this PC ping or
  TCP-connect to arbitrary hosts, including the PLC/OT segment.
- No TLS or basic auth (`--web.config.file` is not set up); the allow-list is IP-based.
- Installs made before this change keep their old permissions on `C:\BlackboxExporter`
  (and any leftover `C:\BlackboxExporterKit`) until `install.bat` is re-run; delete the
  old kit folder by hand.
- `SHA256SUMS` ships in the same zip as the binaries, so it does not protect against a
  tampered zip. Verify the zip's own `.sha256`.
