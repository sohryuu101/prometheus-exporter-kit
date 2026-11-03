# MSSQL exporter Windows package (NSSM)

Windows/amd64 kit for `sql_exporter` (burningalchemist) v0.24.0, installed as a
Windows service (`mssql_exporter`, `C:\MssqlExporter`, auto-start, port 9399)
using NSSM. The version and `config.yml.tmpl` match `../mssql-exporter` (Linux).

## Contents
- `sql_exporter.exe` — v0.24.0 windows-amd64, identical to the upstream release.
  Not committed (it is ~95 MB): `prepare-offline.sh` stages it.
- `config.yml.tmpl` — the SQL collectors and the two target DSNs, with `${...}` placeholders
- `install.ps1` — prompts for the password, renders `config.yml`, locks it down
- `install.bat` / `uninstall.bat` — run as Administrator
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc)
- `SHA256SUMS` — upstream hashes of both executables

## Flow
1. Stage the binaries: `./template/prepare-offline.sh mssql-exporter-windows`
   (downloads them and verifies each against `SHA256SUMS`; a mismatch stages nothing).
2. Build the zip: `./template/package.sh mssql-exporter-windows` (about 28 MB).
3. Transfer the zip to the PC by whatever channel you have, and extract it.
4. Right-click `install.bat` → Run as administrator. It asks for:
   - the Prometheus server's IPs/CIDRs (`PROMETHEUS_ALLOW`, see below);
   - the main and backup database addresses (`IP[:port]`);
   - the SQL username, then the password, which is not echoed. Use a dedicated
     read-only monitoring login (`VIEW SERVER STATE`), not `sa`.
5. Verify: `http://localhost:9399/metrics`
6. Prometheus job: `./template/prometheus-jobs/render-job.sh mssql`

Re-run `install.bat` to change the addresses or the credentials; it prompts again.
`install.bat` validates the rendered config with `sql_exporter.exe -config.check`
before installing the service, and offers to stop if the check fails.

## What the installer protects

- **Install folder.** `install.ps1` refuses a junction/symlink at
  `C:\MssqlExporter`, then restricts the folder to SYSTEM and Administrators
  (inheritance removed, matched by SID so it works on non-English Windows) and
  re-reads the ACL, failing if anything else can reach it. Only then are the
  config and the executables written, so a low-privilege user can neither read
  the SQL login nor replace `sql_exporter.exe` (which runs as LocalSystem).
- **Binaries.** After copying, `install.bat` hashes the copies *inside* the
  locked folder and compares them with `SHA256SUMS`; a mismatch aborts before
  the service is installed.
- **Credentials.** The password is prompted for inside PowerShell, so it never
  appears on a command line. `config.yml` holds it percent-encoded, is created
  fresh (`CreateNew`, so a planted link fails the install) and is restricted to
  SYSTEM (read) and Administrators (full). Nothing secret is stored in the kit.
- **Connection encryption.** The DSNs use `encrypt=true`. The server certificate
  is not validated by default (`TrustServerCertificate=true`) because most SQL
  Servers use a self-signed one; that stops passive sniffing but not an active
  man-in-the-middle. Set `MSSQL_TRUST_CERT=false` before running `install.bat`
  once the server has a trusted certificate. `MSSQL_ENCRYPT=disable` exists only
  for servers that cannot do TLS 1.2.
- **Network access.** With `PROMETHEUS_ALLOW` set (comma-separated, no spaces),
  `install.bat` adds the inbound firewall rule `mssql_exporter (Prometheus only)`
  for port 9399 from those addresses. Empty keeps a rule from an earlier install,
  or leaves the port open with a warning. `uninstall.bat` removes the rule.

## What is still exposed

- The firewall rule only matters while Windows Firewall is on; the installer
  warns when a profile is OFF (it matches the English word, so it can miss this
  on a localized Windows). Another broader allow rule for 9399 would also defeat it.
- There is no TLS or basic auth on the metrics endpoint itself
  (`--web.config.file` if you need it).
- `uninstall.bat` leaves `config.yml` (with the SQL login) in place — delete it
  when decommissioning the host.
