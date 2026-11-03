# Windows exporter package (NSSM)

Windows/amd64 kit for `windows_exporter` v0.25.1, installed as a Windows service
(`windows_exporter`, `C:\WindowsExporter`, auto-start, port 9182) using NSSM. The
same package works on every PC; no site values are needed.

## Contents
- `windows_exporter-0.25.1-amd64.exe` — identical to the upstream prometheus-community release (not committed; stage it)
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc)
- `install.bat` / `uninstall.bat` — run as Administrator
- `SHA256SUMS` — hashes of both executables (check with `certutil -hashfile <file> SHA256`)

## Flow
1. Stage the binaries (downloads the upstream .exe and NSSM, verifies both against
   `SHA256SUMS`):
   `./template/prepare-offline.sh windows-exporter`
2. Build the zip: `./template/package.sh windows-exporter`.
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator.
5. Verify: `http://localhost:9182/metrics`.
6. Scrape job for Prometheus, after installing: `template/prometheus-jobs/render-job.sh windows`.

Remove with `uninstall.bat` (as administrator); files in `C:\WindowsExporter` are left.

## Security notes (known, accepted for now)
- The exporter listens on all interfaces (`:9182`) without authentication, so anyone who
  can reach the port can read the PC's metrics. Mitigations when ready: allow inbound
  9182 only from the Prometheus server in Windows Firewall, or `--web.config.file` for
  basic auth/TLS.
- `install.bat` installs to `C:\WindowsExporter` with default permissions, and the
  service runs as LocalSystem. On a default setup, any authenticated user can write
  there and replace `windows_exporter.exe`, which then runs as SYSTEM at the next
  restart. Mitigation when ready: `icacls C:\WindowsExporter /inheritance:r /grant
  SYSTEM:(OI)(CI)F Administrators:(OI)(CI)F`. Not an issue if only administrators can
  log on to these PCs.
