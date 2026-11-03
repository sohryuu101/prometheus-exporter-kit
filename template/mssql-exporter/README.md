# MSSQL exporter offline package

Copy this whole directory to a Linux/amd64 server. It includes the pinned
binary archive and checksum under `dist/`, installer, SQL config and service
templates.

1. Run `sudo ./install.sh` from this directory. It verifies the archive, then
   prompts for the two database addresses (`TARGET_IP_MAIN`, `TARGET_IP_BACKUP`),
   the SQL username and the hidden password, and writes the rendered config with
   owner-only permissions under `/etc/mssql_exporter/`. Pre-set `TARGET_IP_MAIN` /
   `TARGET_IP_BACKUP` in the environment to skip the address prompts.
2. Prometheus job: after installing, run
   `template/prometheus-jobs/render-job.sh mssql` and paste the YAML into Prometheus.

Nothing site-specific or secret is saved in the package. Re-run the installer to
change the addresses or credentials; it will prompt again.
