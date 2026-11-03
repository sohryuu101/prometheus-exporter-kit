# Windows exporter package (NSSM)

Windows/amd64 kit for `windows_exporter` v0.25.1, installed as a Windows service
(`windows_exporter`, `C:\WindowsExporter`, auto-start, port 9182) using NSSM. The
same package works on every PC; no site values are needed.

## Contents
- `windows_exporter-0.25.1-amd64.exe` — identical to the upstream prometheus-community release (not committed; stage it)
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc)
- `install.bat` / `uninstall.bat` — run as Administrator
- `SHA256SUMS` — hashes of both executables; `install.bat` checks the copied files against it (manual check: `certutil -hashfile <file> SHA256`)

## Flow
1. Stage the binaries (downloads the upstream .exe and NSSM, verifies both against
   `SHA256SUMS`):
   `./template/prepare-offline.sh windows-exporter`
2. Build the zip: `./template/package.sh windows-exporter`.
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator (set `PROMETHEUS_ALLOW` first for unattended runs, or answer the prompt).
5. Verify: `http://localhost:9182/metrics`.
6. Scrape job for Prometheus, after installing: `template/prometheus-jobs/render-job.sh windows`.

Remove with `uninstall.bat` (as administrator); it also deletes the firewall rule. Files in `C:\WindowsExporter` are left.

## Security notes
What `install.bat` now does:
- **Install folder is locked down.** `C:\WindowsExporter` is created, its owner set to
  Administrators, `icacls /reset` clears leftovers, and only SYSTEM (`S-1-5-18`) and
  Administrators (`S-1-5-32-544`) get access (inheritance removed). This happens before any
  file is copied in. A PowerShell check then confirms only those two SIDs appear in the
  ACL; if anything else shows up, the install aborts. Normal users cannot replace
  `windows_exporter.exe`, which runs as SYSTEM.
- **Binaries are verified on the target.** After copying into the locked folder, the
  SHA-256 of `windows_exporter.exe` (matched to `windows_exporter-0.25.1-amd64.exe` in
  `SHA256SUMS`) and `nssm.exe` is compared with the shipped `SHA256SUMS`. A mismatch or
  missing entry aborts before the service is installed or started. `SHA256SUMS` must be in
  the zip; the install fails if it is missing.
- **Firewall restriction.** Set `PROMETHEUS_ALLOW` (comma-separated IPs/CIDRs of the
  Prometheus server[s], no spaces) in the environment, or enter it when asked. The rule
  `windows_exporter (Prometheus only)` then allows inbound TCP 9182 from those addresses
  only. `uninstall.bat` deletes the rule. Unattended runs (no console) get an empty
  answer, which means no restriction plus a WARNING.

Remaining risks:
- The firewall rule only helps while Windows Firewall is on for the active profile. The
  installer warns if a profile is OFF (the check looks for the English word `OFF`, so it
  may miss it on localized Windows). A blocking rule from group policy or another allow
  rule for 9182 can still open the port.
- With `PROMETHEUS_ALLOW` empty, port 9182 stays open to the whole network.
- No TLS or basic auth: traffic is plain HTTP and the allow-list is IP-based (spoofable
  on the local segment). Use `--web.config.file` if that matters.
- Installs made before this change keep their old permissions on `C:\WindowsExporter`
  (writable by any authenticated user) until `install.bat` is re-run.
- `SHA256SUMS` travels in the same zip as the binaries, so it protects against corruption
  and swapped binaries, not against a tampered zip. Verify the zip's own `.sha256`.
