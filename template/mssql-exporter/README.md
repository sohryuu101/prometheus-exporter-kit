# MSSQL exporter offline package

Copy this whole directory to a Linux/amd64 server. It includes the binary
archive under `dist/`, the pinned upstream hash in `SHA256SUMS`, installer, SQL
config and service templates.

1. Run `sudo ./install.sh` from this directory. It checks the archive against
   the pinned hash, then
   prompts for the two database addresses (`TARGET_IP_MAIN`, `TARGET_IP_BACKUP`),
   the SQL username and the hidden password, and writes the rendered config with
   owner-only permissions under `/etc/mssql_exporter/`. Pre-set `TARGET_IP_MAIN` /
   `TARGET_IP_BACKUP` in the environment to skip the address prompts.
2. Prometheus job: after installing, run
   `template/prometheus-jobs/render-job.sh mssql` and paste the YAML into Prometheus.

Nothing site-specific or secret is saved in the package. Re-run the installer to
change the addresses or credentials; it will prompt again.

Use a dedicated read-only monitoring login (`VIEW SERVER STATE`), not `sa`.

## Connection encryption

The DSNs use `encrypt=true`, so the SQL login and results travel over TLS.
`TrustServerCertificate=true` is the default because most SQL Servers present a
self-signed certificate; that stops passive sniffing but not an active
man-in-the-middle. Once the server has a certificate this host trusts, install
with `MSSQL_TRUST_CERT=false` to validate it. `MSSQL_ENCRYPT=disable` exists only
for servers that cannot do TLS 1.2, and prints a warning.

## Network exposure

The exporter has no authentication of its own and listens on `:9399`. The
installer asks for `PROMETHEUS_ALLOW` (comma-separated IPs/CIDRs of the
Prometheus server; pre-set it in the environment to skip the prompt) and writes
`/etc/systemd/system/<unit>.d/10-ip-allow.conf` with `IPAddressDeny=any` and
`IPAddressAllow=localhost <those addresses>` plus the two database addresses, which the exporter itself must reach. Leaving it empty keeps an
existing restriction, or leaves the port open with a warning.

systemd enforces this only from v235 with cgroup v2 (EL8 in its default cgroup
v1 mode and EL7 do not); the installer warns when it cannot, and the host
firewall must then do the job instead.
