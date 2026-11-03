# Blackbox exporter offline package

Linux/amd64 conversion of the Windows BlackboxExporterKit. One exporter per
probing host; it probes PLCs (ICMP by default) and exposes `/probe` on :9115.
The exporter config (`blackbox.yml`) is generic: PLC targets live only in the
Prometheus scrape job (`template/prometheus-jobs/render-job.sh blackbox`).

1. On the workstation run `./template/package.sh blackbox-exporter`. It needs
   no site values and writes `out/blackbox-exporter.tar.gz`.
2. On the server: untar, `sudo bash install.sh`. It verifies the archive
   checksum, installs the binary and `/etc/blackbox_exporter/blackbox.yml`,
   and runs the unit with `CAP_NET_RAW` so ICMP works without root.
3. Run `template/prometheus-jobs/render-job.sh blackbox` (asks for the PLC IPs) and
   paste the YAML into Prometheus.

Verify: `curl 'localhost:9115/probe?target=<plc-ip>&module=icmp'`. For an HTTPS
target with a self-signed certificate use module `http_2xx_tls_skip`.

## Security risk (known, accepted for now)
The exporter listens on all interfaces (`:9115`) and `/probe` accepts any
`target` and `module`, so anyone who can reach the port can make this host probe
arbitrary addresses, including the PLC/OT segment. `blackbox.yml` also ships
modules the scrape job never uses (`http_post_2xx`, `tcp_connect`,
`http_2xx_tls_skip`, `irc_banner`, `ssh_banner*`, `grpc*`, `postgresql`,
`http_3xx`). Mitigations to apply when ready: trim `blackbox.yml` to `icmp` (and
`tcp_connect` if needed); bind with `--web.listen-address=<TARGET_IP_MAIN>:9115`;
allow inbound 9115 only from the Prometheus server (host firewall); optionally add
`--web.config.file` basic auth/TLS.

The server needs Bash, tar, core utilities, and systemd already installed.
