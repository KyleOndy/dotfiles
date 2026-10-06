---
paths:
  - "nix/modules/nix_modules/monitoring-stack/**"
  - "nix/modules/nix_modules/caddyReverseProxy.nix"
  - "nix/modules/hm_modules/terminal/email.nix"
  - "nix/hosts/tiger/configuration.nix"
  - "nix/hosts/pika/configuration.nix"
  - "nix/hosts/cogsworth/configuration.nix"
  - "nix/hosts/trex/configuration.nix"
---

# Monitoring stack config

Grafana dashboard rules live in
`nix/modules/nix_modules/monitoring-stack/DASHBOARD_CONVENTIONS.md`.

### Label naming: `host`, not `instance`

`instance` renders as `127.0.0.1:9100`; `host` renders as `tiger`. Every
scrape config must set a `host` label, and every dashboard query that can span
hosts must filter on it (single-source panels like UniFi and the monitoring
stack's own metrics do not). Full rules and the migration one-liners for imported dashboards are in
`DASHBOARD_CONVENTIONS.md`.

### Authentication

Caddy protects the VictoriaMetrics write endpoints, the Loki push endpoint,
and the whole vmalert and Alertmanager UIs with HTTP basic auth. Those two
UIs are not read-only: they create and expire silences.

tiger sets `monitoringStack.monitoringBasicAuth` to a sops secret holding
`username bcrypt-hash` lines (sops key `monitoring_basicauth`); Caddy checks
it per site via `basicAuthPaths` in
`nix/modules/nix_modules/caddyReverseProxy.nix`. Remote agents on pika,
cogsworth and trex send the matching credentials from sops key
`monitoring_password`.

Loopback callers bypass all of this: vmalert's notifier and tiger's upssched
dispatcher post to `127.0.0.1:9093` directly.

Caddy terminates TLS and provisions its own certs, so `security.acme` is not
involved.

### SMTP

One MXRoute account at `london.mxroute.com:587` sends as
`monitoring@ondy.org` to `kyle@ondy.org`, shared by Alertmanager and
Grafana (`monitoring-stack/default.nix`, sops key
`monitoring_smtp_password`). MXRoute uses server-specific hostnames, so keep
this in step with `nix/modules/hm_modules/terminal/email.nix`; check
`dig ondy.org MX +short` if the provider changes.

### Adding an exporter

1. Write `monitoring-stack/<name>.nix` with options under
   `systemFoundry.monitoringStack.<name>`, gated on
   `mkIf (parentCfg.enable && cfg.enable)`.
2. Nothing to register: `flake.nix` imports every `.nix` under
   `nix/modules/nix_modules/`.
3. Add a scrape job in the host's `vmagent.scrapeConfigs`, with
   `labels.host = "<hostname>"`.

### Dashboards

Seven, each the investigation surface for one or more alert groups. A
dashboard nothing can send you to does not earn its place:

| Dashboard                 | Alert groups it serves                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------ |
| `Hosts`                   | resource_usage, host_availability, disk_space, systemd_health                              |
| `Storage and Data Safety` | zfs_storage, backup_replication, offsite_archive, windows_backup, git_backup, drive_health |
| `Media`                   | media_services_tiger, arr_queue_health, ytdl_sub, ytdl_sub_logs (Loki)                     |
| `Cogsworth`               | cogsworth_monitoring                                                                       |
| `Caddy Reverse Proxy`     | tls_certificates (no cert panel yet), reads Loki                                           |
| `UniFi Network`           | unifi                                                                                      |
| `Monitoring Stack Health` | monitoring_stack                                                                           |

JellyfinDown is an alert in systemd_health rather than a group of its own.
textfile_collector, audio_language and Loki's ruler_heartbeat have no
dashboard yet.

Drop the JSON in `monitoring-stack/dashboards/<folder>/` and fix its label
references per `DASHBOARD_CONVENTIONS.md`. That is the whole procedure:
`grafana.nix` walks the directory with `listFilesRecursive`, and the
subdirectory becomes the Grafana folder. Grafana reloads every 10 seconds.

Before writing a panel, prove the query returns rows:

```bash
ssh tiger 'curl -sG --data-urlencode "query=<promql>" \
  http://127.0.0.1:8428/api/v1/query | jq ".data.result | length"'
```

A `0` here is a panel that will ship broken. `scrape_samples_scraped == 0`
finds the nastier version, where the endpoint answers and parses to nothing
while `up` still reads 1; `ScrapeReturnedNoSamples` alerts on it.
