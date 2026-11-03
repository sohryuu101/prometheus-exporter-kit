# Blackbox exporter offline package

Linux/amd64 conversion of the Windows BlackboxExporterKit. One exporter per
probing host; it probes PLCs (ICMP by default) and exposes `/probe` on :9115.
The exporter config (`blackbox.yml`) is generic: PLC targets live only in the
Prometheus scrape job (`template/prometheus-jobs/render-job.sh blackbox`).

1. On the workstation run `./template/package.sh blackbox-exporter`. It needs
   no site values and writes `out/blackbox-exporter.tar.gz`.
2. On the server: untar, `sudo bash install.sh`. It checks the archive
   against the pinned upstream hash in `SHA256SUMS`, installs the binary and `/etc/blackbox_exporter/blackbox.yml`,
   and runs the unit with `CAP_NET_RAW` so ICMP works without root.
3. Run `template/prometheus-jobs/render-job.sh blackbox` (asks for the PLC IPs) and
   paste the YAML into Prometheus.

Verify: `curl 'localhost:9115/probe?target=<plc-ip>&module=icmp'`.

## Network exposure
`/probe` accepts any `target`, so anyone who can reach port 9115 can make this
host probe addresses of their choosing. Two things limit that:

- `blackbox.yml` carries `icmp` (what the scrape job uses), `tcp_connect`,
  `http_2xx` and `http_2xx_tls_skip` (HTTPS with a self-signed certificate).
  The unused gRPC, SSH, IRC, POST and similar modules are removed.
- The installer asks for `PROMETHEUS_ALLOW` (the Prometheus server's IPs/CIDRs)
  and `PROBE_NETWORKS` (the CIDRs this host probes, e.g. the PLC segment); both
  can be pre-set in the environment. With both set it writes a systemd drop-in
  (`IPAddressDeny=any`, `IPAddressAllow=localhost` plus both lists), so only
  Prometheus can scrape and probes can only reach those networks. The filter
  applies to the probes too, which is why `PROBE_NETWORKS` is needed: without it
  no restriction is written and the installer warns.

systemd enforces this only from v235 with cgroup v2 (not EL7, nor EL8 in its
default cgroup v1 mode); the installer warns when it cannot, and the host
firewall must then restrict inbound 9115 instead. No TLS or basic auth is
configured (`--web.config.file` if you need it).

The server needs Bash, tar, core utilities, and systemd already installed.
