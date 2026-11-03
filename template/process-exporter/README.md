# Process exporter offline package

Copy this whole directory to a Linux/amd64 server. It includes the binary
archive under `dist/`, the pinned upstream hash in `SHA256SUMS`, installer, default process
grouping config, and service template.

1. Review `config.yml` and adjust process matching rules for this host
   (or set `EDIT_CONFIG=1` when running `package.sh`).
2. Run `sudo ./install.sh` from this directory. It checks the archive
   against the pinned upstream hash in `SHA256SUMS` before installing.
3. Prometheus job: after installing, run `template/prometheus-jobs/render-job.sh process` and paste the YAML into Prometheus.

The server needs Bash, tar, core utilities, and systemd already
installed.

## Network exposure

The exporter has no authentication of its own and listens on `:9256`. The
installer asks for `PROMETHEUS_ALLOW` (comma-separated IPs/CIDRs of the
Prometheus server; pre-set it in the environment to skip the prompt) and writes
`/etc/systemd/system/<unit>.d/10-ip-allow.conf` with `IPAddressDeny=any` and
`IPAddressAllow=localhost <those addresses>`. Leaving it empty keeps an
existing restriction, or leaves the port open with a warning.

systemd enforces this only from v235 with cgroup v2 (EL8 in its default cgroup
v1 mode and EL7 do not); the installer warns when it cannot, and the host
firewall must then do the job instead.

The service runs as root, which reading every user's `/proc` entries needs, but
`CapabilityBoundingSet` limits it to `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH`,
with a read-only filesystem (`ProtectSystem=strict`).
