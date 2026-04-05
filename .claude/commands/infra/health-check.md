---
allowed-tools: Bash(ssh:*), Bash(curl:*), Read, Grep, Glob, AskUserQuestion
description: Automated health sweep of all elk services with failure investigation
---

# Elk Health Check

Automated health sweep of every service on elk. Runs all checks without interaction, presents a grouped report, investigates any failures, then offers remediation.

If the first SSH call fails, report "elk unreachable" and stop.

## Phase 1: System Health

Run a single SSH call to collect system-level health data:

```bash
ssh elk 'echo "=== UPTIME ===" && uptime && echo "=== FAILED UNITS ===" && systemctl --failed --no-legend && echo "=== DISK ===" && df -h | grep -E "(Filesystem|/$| /mnt/storage| /boot)" && echo "=== MEMORY ===" && free -m && echo "=== RAID ===" && cat /proc/mdstat && echo "=== WIREGUARD ===" && wg show wg-home 2>&1'
```

Check for:

- Any failed systemd units
- Disk usage above 85% on any mount
- Memory pressure (available < 10% of total)
- RAID degraded state (look for `_` in the device line, e.g. `[U_]` means one disk is down)
- WireGuard tunnel up with recent handshake (within 3 minutes; keepalive is 25s)

## Phase 2: Service Unit Status

Run a single SSH call to check all service units:

```bash
ssh elk 'for svc in caddy victoriametrics loki grafana alertmanager vmalert vmagent promtail prometheus-node-exporter jellyfin-exporter exportarr-sonarr exportarr-radarr exportarr-lidarr exportarr-readarr exportarr-prowlarr exportarr-bazarr exportarr-sabnzbd jellyfin jellyseerr sonarr radarr lidarr readarr prowlarr bazarr sabnzbd navidrome bgutil-pot-server docker; do printf "%s:%s\n" "$svc" "$(systemctl is-active $svc.service 2>/dev/null || echo unknown)"; done'
```

Record which services are active vs inactive/failed. Services that are not active will be skipped in Phase 3.

## Phase 3: HTTP Health Probes

Run a single SSH call to probe every health endpoint. Skip any service that was inactive/failed in Phase 2.

```bash
ssh elk 'for check in "caddy:2019:/metrics" "victoriametrics:8428:/health" "loki:3100:/ready" "grafana:3000:/api/health" "alertmanager:9093:/-/healthy" "vmalert:8880:/health" "vmagent:8429:/health" "promtail:9080:/ready" "prometheus-node-exporter:9100:/metrics" "jellyfin-exporter:9594:/metrics" "exportarr-sonarr:9707:/metrics" "exportarr-radarr:9708:/metrics" "exportarr-lidarr:9709:/metrics" "exportarr-readarr:9710:/metrics" "exportarr-prowlarr:9711:/metrics" "exportarr-bazarr:9712:/metrics" "exportarr-sabnzbd:9713:/metrics" "jellyfin:8096:/health" "jellyseerr:5055:/" "sonarr:8989:/ping" "radarr:7878:/ping" "lidarr:8686:/ping" "readarr:8787:/ping" "prowlarr:9696:/ping" "bazarr:6767:/" "sabnzbd:8080:/sabnzbd/api?mode=version" "navidrome:4533:/"; do IFS=: read -r name port path <<< "$check"; code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${port}${path}" 2>/dev/null || echo "000"); printf "%s:%s:%s\n" "$name" "$port" "$code"; done'
```

A healthy response is any 2xx or 3xx HTTP status. Anything else (4xx, 5xx, 000/timeout) is a failure.

## Phase 4: Timer Status

Check all timers in a single SSH call:

```bash
ssh elk 'systemctl list-timers ytdl-sub-youtube_daily.timer ytdl-sub-youtube_weekly.timer jellyfin-prune.timer --no-pager --all'
```

Verify:

- Each timer is listed and active
- `ytdl-sub-youtube_daily.timer`: last trigger within 25 hours
- `ytdl-sub-youtube_weekly.timer`: last trigger within 8 days
- `jellyfin-prune.timer`: last trigger within 25 hours

If a timer shows "n/a" for LAST, it hasn't run yet since boot (not necessarily an error if the host was recently rebooted).

## Phase 5: Alertmanager Active Alerts

Query alertmanager for any active alerts:

```bash
ssh elk 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq "[.[] | select(.status.state == \"active\") | {alert: .labels.alertname, severity: .labels.severity, host: .labels.host, summary: .annotations.summary}]"'
```

Report any active alerts. These are already-known issues that the monitoring stack has flagged.

## Phase 6: External Connectivity

Run a single SSH call to verify outbound connectivity:

```bash
ssh elk 'echo "=== DNS ===" && dig +short example.com @1.1.1.1 && echo "=== HTTPS ===" && curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://www.google.com'
```

Check:

- DNS resolution returns an IP
- HTTPS returns 200 (or 301)
- WireGuard handshake from Phase 1 is recent (within 3 minutes)

## Phase 7: Report Assembly

Present results as grouped markdown with pass/fail markers. Format:

```
## Summary
X/Y services healthy, N issues found

## System Health
  [PASS] Uptime: 14 days
  [PASS] Disk: / at 42%, /mnt/storage at 67%
  [PASS] Memory: 48G available of 64G
  [PASS] RAID: md0 active raid1 [UU]
  [PASS] WireGuard: wg-home up, last handshake 12s ago
  [FAIL] 1 failed systemd unit: foo.service

## Reverse Proxy
  [PASS] caddy.service - active, HTTP 200

## Monitoring Stack
  [PASS] victoriametrics.service - active, HTTP 200
  ...

## Metrics Collection
  [PASS] vmagent.service - active, HTTP 200
  ...

## Exportarr
  [PASS] exportarr-sonarr.service - active, HTTP 200
  ...

## Media Services
  [PASS] jellyfin.service - active, HTTP 200
  ...

## YouTube
  [PASS] bgutil-pot-server.service - active

## Timers
  [PASS] ytdl-sub-youtube_daily.timer - last run 8h ago
  ...

## Connectivity
  [PASS] DNS resolution OK
  [PASS] Outbound HTTPS OK
  [PASS] WireGuard handshake recent

## Active Alerts
  (none) or list of firing alerts
```

## Phase 8: Failure Investigation

For every service or check that failed in Phases 1-6, automatically investigate.

For each failed systemd service:

```bash
ssh elk 'journalctl -u <unit>.service -n 30 --no-pager 2>&1'
ssh elk 'systemctl show <unit>.service -p NRestarts,Result,ActiveEnterTimestamp,InactiveEnterTimestamp --no-pager'
```

For each HTTP health check failure where the service IS active (running but not responding):

```bash
ssh elk 'journalctl -u <unit>.service -n 30 --no-pager 2>&1 | grep -iE "error|fail|panic|fatal|refused|timeout"'
```

Look for common patterns:

- **start-limit-hit**: Service crashed too many times. Needs `systemctl reset-failed` then restart.
- **OOM killed**: Check `journalctl -k | grep -i oom`. Service needs memory limits adjusted.
- **Permission denied**: Check file/device permissions relevant to the service.
- **Connection refused on health check**: Service may still be starting up. Check `ActiveEnterTimestamp` to see if it just restarted.

Present investigation findings grouped by failed service, with log excerpts and diagnosis.

## Phase 9: Action Prompt

After presenting the full report:

- If all services are healthy: report clean bill of health, done.
- If there are failures: use `AskUserQuestion` to ask what to do next. Options:
  1. Attempt to restart failed services
  2. Pull full logs for a specific service (deeper investigation)
  3. No action needed

If the user chooses restart, run `ssh elk sudo systemctl restart <unit>` for each failed service, then re-check its status and health endpoint.

## Service Reference

Complete inventory of elk services. Keep this updated when services are added or removed in `nix/hosts/elk/configuration.nix`.

### Long-running services

| Category      | Unit                             | Port | Health Path               |
| ------------- | -------------------------------- | ---- | ------------------------- |
| Reverse Proxy | caddy.service                    | 2019 | /metrics                  |
| Monitoring    | victoriametrics.service          | 8428 | /health                   |
| Monitoring    | loki.service                     | 3100 | /ready                    |
| Monitoring    | grafana.service                  | 3000 | /api/health               |
| Monitoring    | alertmanager.service             | 9093 | /-/healthy                |
| Monitoring    | vmalert.service                  | 8880 | /health                   |
| Metrics       | vmagent.service                  | 8429 | /health                   |
| Metrics       | promtail.service                 | 9080 | /ready                    |
| Metrics       | prometheus-node-exporter.service | 9100 | /metrics                  |
| Metrics       | jellyfin-exporter.service        | 9594 | /metrics                  |
| Exportarr     | exportarr-sonarr.service         | 9707 | /metrics                  |
| Exportarr     | exportarr-radarr.service         | 9708 | /metrics                  |
| Exportarr     | exportarr-lidarr.service         | 9709 | /metrics                  |
| Exportarr     | exportarr-readarr.service        | 9710 | /metrics                  |
| Exportarr     | exportarr-prowlarr.service       | 9711 | /metrics                  |
| Exportarr     | exportarr-bazarr.service         | 9712 | /metrics                  |
| Exportarr     | exportarr-sabnzbd.service        | 9713 | /metrics                  |
| Media         | jellyfin.service                 | 8096 | /health                   |
| Media         | jellyseerr.service               | 5055 | /                         |
| Media         | sonarr.service                   | 8989 | /ping                     |
| Media         | radarr.service                   | 7878 | /ping                     |
| Media         | lidarr.service                   | 8686 | /ping                     |
| Media         | readarr.service                  | 8787 | /ping                     |
| Media         | prowlarr.service                 | 9696 | /ping                     |
| Media         | bazarr.service                   | 6767 | /                         |
| Media         | sabnzbd.service                  | 8080 | /sabnzbd/api?mode=version |
| Media         | navidrome.service                | 4533 | /                         |
| YouTube       | bgutil-pot-server.service        | -    | systemctl only            |
| Other         | docker.service                   | -    | systemctl only            |

### Network & storage

| Check            | Command            |
| ---------------- | ------------------ |
| WireGuard tunnel | `wg show wg-home`  |
| RAID1 array      | `cat /proc/mdstat` |

### Timers

| Timer                         | Expected Schedule |
| ----------------------------- | ----------------- |
| ytdl-sub-youtube_daily.timer  | Daily at 03:00    |
| ytdl-sub-youtube_weekly.timer | Monday at 03:00   |
| jellyfin-prune.timer          | Daily at 06:00    |

## Common Failure Patterns

### Service hit restart limit (start-limit-hit)

```bash
ssh elk sudo systemctl reset-failed <service>
ssh elk sudo systemctl start <service>
# Then investigate why it was crashing
ssh elk journalctl -u <service> -n 100 --no-pager
```

### Service running but health check fails

Service may still be starting. Check how long it's been active:

```bash
ssh elk systemctl show <service> -p ActiveEnterTimestamp
```

If active for more than 60 seconds and still failing health checks, check logs for errors.

### RAID degraded

```bash
ssh elk cat /proc/mdstat
ssh elk sudo mdadm --detail /dev/md0
```

Look for `[U_]` (one disk down) vs `[UU]` (both disks healthy).

### WireGuard tunnel down

```bash
ssh elk wg show wg-home
ssh elk sudo systemctl restart wireguard-wg-home
ssh elk wg show wg-home
```

Check that endpoint `home.1ella.com:51820` resolves and is reachable.

### Alertmanager not sending emails

```bash
ssh elk journalctl -u alertmanager -n 100 --no-pager | grep -i smtp
```

SMTP server should be `london.mxroute.com:587`.
