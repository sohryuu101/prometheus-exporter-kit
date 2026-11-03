# Node exporter offline package

Copy this whole directory to a Linux/amd64 server. It includes the pinned
binary archive and checksum under `dist/`, installer and service template.

1. Run `sudo ./install.sh` from this directory. It verifies the archive
   checksum before installing. No site values are needed.
2. Prometheus job: after installing, run `template/prometheus-jobs/render-job.sh node` and paste the YAML into Prometheus.

The server needs Bash, tar, core utilities, and systemd already
installed.
