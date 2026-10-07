---
name: monitoring
description: Investigate the homelab monitoring stack on tiger (VictoriaMetrics, Loki, Grafana, Alertmanager, vmalert). Use for a firing alert, a No-data dashboard, a PromQL or LogQL query, or silencing a host.
---

# Homelab monitoring

Paths below are relative to the dotfiles repo, `~/src/dotfiles/main`.

tiger is the server: VictoriaMetrics, Loki, Grafana, Alertmanager, vmalert.
Retention is 400 days for both metrics and logs
(`nix/hosts/tiger/configuration.nix`).

Agents run on tiger, pika, cogsworth and trex: vmagent, alloy, node_exporter.
tiger additionally runs the zfs, jellyfin, exportarr (\*arr plus sabnzbd),
unpoller and nut exporters, and scrapes its own stack (VictoriaMetrics,
vmagent, vmalert, Alertmanager, Loki, alloy, Grafana). nut serves the UPS at
`/ups_metrics`; its `/metrics` is only the exporter's own process. tiger also
scrapes the native endpoints of immich (8081 api, 8082 microservices) and
navidrome (`/metrics` on its app port, which Caddy answers with a 404).
cogsworth exposes the kiosk app at `/api/metrics` and birdnet-go's telemetry on
`127.0.0.1:8091` (predictions and detections; per stream, only dropped audio
chunks and queue depth, so stream liveness comes from Loki), and
cogsworth-db-snapshot writes its last success time and size through the
textfile collector. pika runs zfs_exporter, and exports smartctl health, ZFS
scrub and snapshot age, and the S3 archive counters through the textfile
collector. tiger, pika and trex each export histdb-backup's last snapshot time
the same way, and trex adds `mlx_agent_loaded` (written by mlx-auto-stop, so an
idle-stopped server still reads loaded) and the last mbsync run.

Every UI is `<name>.tiger.infra.ondy.org`, served by Caddy off a wildcard
cert, and answers only private source addresses (LAN, DMZ, WireGuard).
Only apps meant for use away from home (jellyfin, jellyseerr, navidrome,
immich) have public `<name>.apps.ondy.org` aliases; no admin or monitoring
UI does.

The vmalert and Alertmanager UIs are not read-only: they create and expire
silences.

### Silences

`silence-host` (`nix/modules/hm_modules/dev/monitoring.nix`) silences every
alert for one host:

```bash
silence-host cogsworth "7 days" "Maintenance window"
```

Duration is anything `date -d` accepts. For narrower matchers, use the
Alertmanager UI.

### Queries

```bash
# metrics
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/query?query=up" | jq .'
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/label/host/values" | jq .'

# alerts: vmalert is what fires, alertmanager is what routes
ssh tiger 'curl -s http://127.0.0.1:8880/api/v1/alerts | jq .'
ssh tiger 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq .'
```

A dashboard showing "No data" is usually one of five things: the exporter is
down (`systemctl status`), vmagent is not scraping it (no job in
`scrapeConfigs`), the query filters on `instance` instead of `host`, the
metric name never existed, or it is a Loki panel selecting on `job` instead of
`unit`. Loki has three job values (`systemd-journal`, `darwin-unified-log`,
`caddy-access`), so per-service log queries must name the unit.
