# Windows exporter package (NSSM)

Windows/amd64 kit for `windows_exporter` v0.25.1, installed as a Windows service
(`windows_exporter`, `C:\WindowsExporter`, auto-start, port 9182) using NSSM. The
same package works on every PC; no site values are needed.

## Contents
- `windows_exporter-0.25.1-amd64.exe` — identical to the upstream prometheus-community release (not committed; stage it)
- `nssm.exe` — NSSM 2.24 win64 (public domain, from nssm.cc)
- `install.bat` / `uninstall.bat` / `apply-config.bat` — run as Administrator
- `process.include.example` — sample per-process filter (see below)
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

To change the configuration later (add, edit or remove `process.include`), run
`apply-config.bat` — not `install.bat`. It rewrites the service parameters and
restarts the service without copying files or reinstalling anything (see below).

## Per-process CPU and memory (optional)

The kit is vendor-neutral by default: with no extra files, `install.bat` configures
the exporter with its upstream default collector set and passes no
`--collectors.enabled` flag.

To add per-process CPU/memory metrics, put a file named `process.include` next to
`install.bat` before running it. The first line that is neither blank nor a `#`
comment is a Go regexp matched against process names; when the file exists the
installer enables the `process` collector and passes that regexp as the filter:

```
--collectors.enabled=cpu,cs,logical_disk,net,os,physical_disk,service,system,textfile,process
--collector.process.include=<first line of process.include>
```

`process.include.example` holds a regexp for the SPX warehouse (WCS) stack — copy
it on those PCs:

```powershell
Copy-Item process.include.example process.include
```

Leave the file out everywhere else and the kit behaves as it did before.
`--collectors.enabled` replaces the default collector set rather than adding to
it, which is why `install.bat` re-lists every 0.25.1 default when it turns
`process` on. `process.include` is gitignored: it is a per-deployment file, not
part of the kit.

The regexp line is read through PowerShell, so the file may be saved as UTF-8 or
UTF-16, with or without a BOM, and blank lines and `#` comments above it are
ignored. A file named `process.include.txt` (Notepad's hidden extensions) is
rejected with an error instead of being ignored, and a re-run without the file
asks Y/N before it turns the collector off. The value must be plain ASCII, under
900 characters, and must not contain spaces, quotes, `%`, `!`, `&`, `<`, `>` or
`;` — those would break cmd quoting or be truncated. The regexp is compiled
before use, so a typo fails at install time rather than silently producing no
metrics.

Keep the regexp narrow: unfiltered, the process collector emits a metric set for
every process on the PC, which bloats the series count and every scrape. Add
names to the alternation for other vendors; the trailing `(\.exe)?` covers both
`nginx` and `nginx.exe`.

Verify on the PC after installing (either shell):

```powershell
curl.exe -s http://localhost:9182/metrics | findstr windows_process
```

```powershell
(Invoke-WebRequest http://localhost:9182/metrics).Content -split "`n" |
  Select-String 'windows_process'
```

Expected: metrics in the `windows_process_*` family — a CPU-time counter plus one
or more memory gauges. Exact suffixes vary between windows_exporter releases;
take the names from this output rather than from documentation written for a
different version. If nothing appears, the regexp matched no running process —
check the actual image names in Task Manager (Details tab) and adjust the
`process.include` file.

Watch scrape cost: if your scrape job uses a 15s timeout, confirm
`scrape_duration_seconds` stays well below it after enabling the collector; if it
approaches the timeout, narrow the regexp.

## Changing configuration without reinstalling

`install.bat` removes and recreates the service. That is right for a first install
or a version upgrade, but it is heavier than a configuration change needs to be.

For configuration only, run `apply-config.bat` as administrator. It reads
`process.include`, rewrites the service's `AppParameters` in the registry,
restarts the service through the Service Control Manager, and verifies that the
port is listening. No file is copied and the service is not deleted, so none of
the file-lock or "marked for deletion" failure modes of a reinstall apply.

- Run it twice with the same `process.include`: same result, one restart each time.
- Delete `process.include` and run it: per-process metrics are turned off.
- If the new configuration does not come up, it restores the previous
  `AppParameters`, restarts the service, and prints the tail of `service.log`.
- It refuses to run when the service is not installed; use `install.bat` first.

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
