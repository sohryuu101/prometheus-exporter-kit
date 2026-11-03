# Process exporter offline package

Copy this whole directory to a Linux/amd64 server. It includes the pinned
binary archive and checksum under `dist/`, installer, default process
grouping config, and service template.

1. Review `config.yml` and adjust process matching rules for this host
   (or set `EDIT_CONFIG=1` when running `package.sh`).
2. Run `sudo ./install.sh` from this directory. It verifies the archive
   checksum before installing.
3. Prometheus job: after installing, run `template/prometheus-jobs/render-job.sh process` and paste the YAML into Prometheus.

The server needs Bash, tar, core utilities, and systemd already
installed.
