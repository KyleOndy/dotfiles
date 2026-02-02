---
allowed-tools: Bash(ssh:*), Bash(curl:*), Read, Grep, Glob, AskUserQuestion
argument-hint: "[service-name] [--host wolf|bear] [--check alerts|services|zfs|nfs|pipeline|health]"
description: Debug NixOS services on wolf and bear with guided troubleshooting
---

# Infrastructure Service Debugging

Interactive guided debugging for NixOS services on wolf and bear. This skill helps diagnose service failures, investigate alerts, check logs, query metrics, and debug the media pipeline.

## Quick Start

If arguments provided, jump directly to that check. Otherwise, start interactive triage.

## Service Reference

### Wolf (Storage + Acquisition + Monitoring Hub)

| Service           | Unit Name                         | Port    | Health Check                                     |
| ----------------- | --------------------------------- | ------- | ------------------------------------------------ |
| VictoriaMetrics   | victoriametrics.service           | 8428    | <http://127.0.0.1:8428/health>                   |
| Loki              | loki.service                      | 3100    | <http://127.0.0.1:3100/ready>                    |
| Grafana           | grafana.service                   | 3000    | <http://127.0.0.1:3000/api/health>               |
| Alertmanager      | alertmanager.service              | 9093    | <http://127.0.0.1:9093/-/healthy>                |
| vmalert           | vmalert.service                   | 8880    | <http://127.0.0.1:8880/health>                   |
| vmagent           | vmagent.service                   | 8429    | <http://127.0.0.1:8429/health>                   |
| promtail          | promtail.service                  | 3101    | <http://127.0.0.1:3101/ready>                    |
| nginx             | nginx.service                     | 80, 443 | systemctl status nginx                           |
| node_exporter     | prometheus-node-exporter.service  | 9100    | <http://127.0.0.1:9100/metrics>                  |
| nginx_exporter    | prometheus-nginx-exporter.service | 9113    | <http://127.0.0.1:9113/metrics>                  |
| nginxlog_exporter | nginxlog-exporter.service         | 4040    | <http://127.0.0.1:4040/metrics>                  |
| zfs_exporter      | prometheus-zfs-exporter.service   | 9134    | <http://127.0.0.1:9134/metrics>                  |
| Sonarr            | sonarr.service                    | 8989    | <http://127.0.0.1:8989/ping>                     |
| Radarr            | radarr.service                    | 7878    | <http://127.0.0.1:7878/ping>                     |
| Lidarr            | lidarr.service                    | 8686    | <http://127.0.0.1:8686/ping>                     |
| Prowlarr          | prowlarr.service                  | 9696    | <http://127.0.0.1:9696/ping>                     |
| Readarr           | readarr.service                   | 8787    | <http://127.0.0.1:8787/ping>                     |
| SABnzbd           | sabnzbd.service                   | 8080    | <http://127.0.0.1:8080/sabnzbd/api?mode=version> |
| Subtitle Extract  | (webhook script, not a service)   | -       | ls /etc/scripts/subtitle-extract-notify.sh       |
| NFS Server        | nfs-server.service                | 2049    | systemctl status nfs-server                      |
| ZFS               | zfs.target                        | -       | zpool status                                     |
| WireGuard         | wg-quick-wg0.service              | -       | wg show wg0                                      |

### Bear (Compute + Transcoding + Playback)

| Service            | Unit Name                         | Port | Health Check                             |
| ------------------ | --------------------------------- | ---- | ---------------------------------------- |
| Jellyfin           | jellyfin.service                  | 8096 | <http://127.0.0.1:8096/health>           |
| Tdarr Server       | tdarr-server.service              | 8266 | <http://127.0.0.1:8266/api/v2/status>    |
| Tdarr Node         | tdarr-node.service                | 8267 | Check logs                               |
| Subtitle Extractor | subtitle-extractor.service/.timer | -    | systemctl list-timers subtitle-extractor |
| vmagent            | vmagent.service                   | 8429 | <http://127.0.0.1:8429/health>           |
| promtail           | promtail.service                  | 3101 | <http://127.0.0.1:3101/ready>            |
| node_exporter      | prometheus-node-exporter.service  | 9100 | <http://127.0.0.1:9100/metrics>          |
| NFS Client         | wolf-media.mount                  | -    | mount \| grep nfs                        |
| WireGuard          | wg-quick-wg0.service              | -    | wg show wg0                              |

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│ WOLF (Storage + Acquisition + Monitoring)                   │
│                                                             │
│  ZFS Pool (tiger-pool)                                      │
│    └─ /tiger-pool/media/{tv,movies,music,books}            │
│                                                             │
│  NFS Exports → /tiger-pool/media                            │
│                                                             │
│  Acquisition Stack:                                         │
│    SABnzbd → Sonarr/Radarr/Lidarr/Readarr → /tiger-pool/   │
│                                                             │
│  Monitoring Hub:                                            │
│    VictoriaMetrics ← vmagent (wolf + bear)                  │
│    Loki ← promtail (wolf + bear)                            │
│    Grafana → queries → VictoriaMetrics + Loki               │
│    vmalert → evaluates → sends → Alertmanager → Email      │
└─────────────────────────────────────────────────────────────┘
                              │
                    WireGuard VPN (wg0)
                              │
┌─────────────────────────────────────────────────────────────┐
│ BEAR (Compute + Transcoding + Playback)                     │
│                                                             │
│  NFS Mount: wolf:/tiger-pool/media → /mnt/media            │
│                                                             │
│  Jellyfin (playback) → reads → /mnt/media                   │
│                                                             │
│  Tdarr (transcoding):                                       │
│    Server → manages jobs                                    │
│    Node → QuickSync GPU → transcodes → writes /mnt/media   │
│                                                             │
│  Metrics/Logs → vmagent/promtail → wolf                     │
└─────────────────────────────────────────────────────────────┘
```

## Media Pipeline Flow

```text
1. Usenet → SABnzbd (wolf:8080) downloads to /tiger-pool/incomplete
2. *arr apps monitor SABnzbd queue
3. On completion: *arr imports to /tiger-pool/media/{tv,movies,music,books}
3a. Subtitle webhook extracts sidecar .srt files on import (wolf)
3b. Hourly timer backfills any missing .srt sidecars (bear)
4. Jellyfin (bear:8096) scans /mnt/media (NFS mount)
5. Tdarr Server (bear:8266) watches /mnt/media for new files
6. Tdarr Node (bear:8267) picks up jobs, transcodes with QuickSync
7. Transcoded files written back to /mnt/media → wolf:/tiger-pool/media
```

## Interactive Triage

Ask user what they want to investigate:

1. **Service down** - Specific service not running/responding
2. **Alert fired** - Investigate a specific alert from Alertmanager
3. **Media pipeline** - Debug acquisition/transcoding/playback flow
4. **Storage/NFS** - ZFS health, NFS connectivity, disk space
5. **General health** - Overall system health check

Based on response, jump to appropriate section.

## Debugging Procedures

### 1. Service Status Check

For a specific service on a specific host:

```bash
# Check service status
ssh <host> systemctl status <service-name>

# Check recent logs (last 50 lines)
ssh <host> journalctl -u <service-name> -n 50

# Check if service is enabled
ssh <host> systemctl is-enabled <service-name>

# Check if service is active
ssh <host> systemctl is-active <service-name>

# Check restart count (detect crash loops)
ssh <host> systemctl show <service-name> -p NRestarts -p Result

# If service hit restart limit, reset it
ssh <host> sudo systemctl reset-failed <service-name>
ssh <host> sudo systemctl start <service-name>
```

### 2. Alert Investigation

Check what alerts are currently firing:

```bash
# vmalert - alerts being evaluated
ssh wolf 'curl -s http://127.0.0.1:8880/api/v1/alerts | jq .'

# Alertmanager - alerts that have fired and been sent
ssh wolf 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq .'

# Filter for active alerts only
ssh wolf 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq ".[] | select(.status.state == \"active\")"'

# Check alert rules
ssh wolf 'curl -s http://127.0.0.1:8880/api/v1/rules | jq .'
```

For a specific alert, query the underlying metric:

```bash
# Example: Check if service is actually down
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=up{job=\"<job-name>\"}" | jq .'
```

### 3. ZFS Health Check

```bash
# Pool status (look for DEGRADED, FAULTED, errors)
ssh wolf zpool status -v

# Pool capacity and health
ssh wolf zpool list

# Dataset usage
ssh wolf zfs list

# Check for scrub errors
ssh wolf zpool status -v | grep -i error

# Check last scrub time
ssh wolf zpool status | grep scan

# Check ZFS metrics in VictoriaMetrics
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=zfs_pool_health{host=\"wolf\"}" | jq .'
```

### 4. NFS Debugging

#### Wolf (NFS Server)

```bash
# Check NFS server is running
ssh wolf systemctl status nfs-server

# Check exports are configured
ssh wolf cat /etc/exports

# Check active NFS connections
ssh wolf showmount -a

# Check NFS metrics
ssh wolf ss -tpn | grep :2049
```

#### Bear (NFS Client)

```bash
# Check mount status
ssh bear mount | grep nfs

# Check if mount unit is active
ssh bear systemctl status wolf-media.mount

# Test NFS connectivity
ssh bear ls -la /mnt/media

# Check mount options
ssh bear cat /proc/mounts | grep nfs

# Check NFS client stats
ssh bear nfsstat -c

# Remount if stale
ssh bear sudo systemctl restart wolf-media.mount
```

#### WireGuard Connectivity (Required for NFS)

```bash
# Wolf WireGuard status
ssh wolf wg show wg0

# Bear WireGuard status
ssh bear wg show wg0

# Test WireGuard connectivity (bear → wolf)
ssh bear ping -c 3 10.100.0.1  # wolf's WireGuard IP

# Test WireGuard connectivity (wolf → bear)
ssh wolf ping -c 3 10.100.0.2  # bear's WireGuard IP

# Check WireGuard service
ssh wolf systemctl status wg-quick-wg0
ssh bear systemctl status wg-quick-wg0
```

### 5. Media Pipeline Debugging

#### Step 1: SABnzbd (Download)

```bash
# Check SABnzbd status
ssh wolf systemctl status sabnzbd

# Check SABnzbd queue via API
ssh wolf 'curl -s "http://127.0.0.1:8080/sabnzbd/api?mode=queue&output=json&apikey=<API_KEY>" | jq .'

# Check SABnzbd history
ssh wolf 'curl -s "http://127.0.0.1:8080/sabnzbd/api?mode=history&output=json&apikey=<API_KEY>" | jq .'

# Check logs for errors
ssh wolf journalctl -u sabnzbd -n 50 | grep -i error
```

#### Step 2: \*arr Apps (Import/Management)

```bash
# Check Sonarr/Radarr status
ssh wolf systemctl status sonarr
ssh wolf systemctl status radarr

# Check queue depth (metric)
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=sonarr_queue_total" | jq .'
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=radarr_queue_total" | jq .'

# Check *arr logs for import errors
ssh wolf journalctl -u sonarr -n 100 | grep -i "import"
ssh wolf journalctl -u radarr -n 100 | grep -i "import"

# Check disk space for imports
ssh wolf df -h /tiger-pool/media
```

#### Step 3: Jellyfin (Playback)

```bash
# Check Jellyfin status (on bear)
ssh bear systemctl status jellyfin

# Check Jellyfin can see NFS mount
ssh bear ls -la /mnt/media/tv /mnt/media/movies

# Check Jellyfin logs for scan errors
ssh bear journalctl -u jellyfin -n 100 | grep -i "error\|scan"

# Check Jellyfin API health
ssh bear 'curl -s http://127.0.0.1:8096/health | jq .'
```

#### Step 4: Tdarr (Transcoding)

```bash
# Check Tdarr server status
ssh bear systemctl status tdarr-server

# Check Tdarr node status
ssh bear systemctl status tdarr-node

# Check Tdarr server API
ssh bear 'curl -s http://127.0.0.1:8266/api/v2/status | jq .'

# Check Tdarr node logs (GPU access, transcode errors)
ssh bear journalctl -u tdarr-node -n 100

# Check GPU availability (QuickSync)
ssh bear ls -la /dev/dri/renderD128

# Check Tdarr node can write to NFS
ssh bear touch /mnt/media/.tdarr-write-test && ssh bear rm /mnt/media/.tdarr-write-test
```

#### Full Pipeline Health Check

```bash
# Check all services in pipeline
for svc in sabnzbd sonarr radarr lidarr readarr; do
  echo "=== $svc on wolf ==="
  ssh wolf systemctl is-active $svc
done

for svc in jellyfin tdarr-server tdarr-node; do
  echo "=== $svc on bear ==="
  ssh bear systemctl is-active $svc
done

# Check queue metrics
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=sonarr_queue_total" | jq -r ".data.result[0].value[1]"'
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=radarr_queue_total" | jq -r ".data.result[0].value[1]"'
```

### 6. General Health Check

Run this to get overall system status:

```bash
# === WOLF HEALTH ===

# Failed units
echo "=== Failed units on wolf ==="
ssh wolf systemctl --failed

# Disk space
echo "=== Disk space on wolf ==="
ssh wolf df -h | grep -E "(Filesystem|/tiger-pool|/$)"

# ZFS pool health
echo "=== ZFS health ==="
ssh wolf zpool status | head -20

# WireGuard status
echo "=== WireGuard (wolf) ==="
ssh wolf wg show wg0 | grep -E "(interface|peer|latest handshake)"

# Firing alerts
echo "=== Firing alerts ==="
ssh wolf 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq ".[] | select(.status.state == \"active\") | {alertname: .labels.alertname, severity: .labels.severity, summary: .annotations.summary}"'

# === BEAR HEALTH ===

# Failed units
echo "=== Failed units on bear ==="
ssh bear systemctl --failed

# Disk space
echo "=== Disk space on bear ==="
ssh bear df -h | grep -E "(Filesystem|/mnt/media|/$)"

# NFS mount status
echo "=== NFS mount (bear) ==="
ssh bear mount | grep nfs

# WireGuard status
echo "=== WireGuard (bear) ==="
ssh bear wg show wg0 | grep -E "(interface|peer|latest handshake)"

# GPU access (Tdarr)
echo "=== GPU access (bear) ==="
ssh bear ls -la /dev/dri/renderD128
```

### 7. Metrics Query Reference

Query VictoriaMetrics directly for service health:

```bash
# Check if service is up (1 = up, 0 = down)
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=up{host=\"<host>\",job=\"<job>\"}" | jq .'

# Memory usage by host
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=node_memory_MemAvailable_bytes{host=\"<host>\"}" | jq .'

# CPU usage by host
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=100-(avg(rate(node_cpu_seconds_total{mode=\"idle\",host=\"<host>\"}[5m]))*100)" | jq .'

# Disk space remaining
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=node_filesystem_avail_bytes{host=\"<host>\",mountpoint=\"/\"}" | jq .'

# ZFS pool health (0 = ONLINE, 1+ = DEGRADED/FAULTED)
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=zfs_pool_health{host=\"wolf\"}" | jq .'

# Sonarr/Radarr queue depth
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=sonarr_queue_total" | jq .'
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/query?query=radarr_queue_total" | jq .'

# List all available metrics for a job
ssh wolf 'curl -s "http://127.0.0.1:8428/api/v1/label/__name__/values?match[]={job=\"<job>\"}" | jq .'
```

### 8. Loki Log Query Reference

Query Loki directly for service logs:

```bash
# Get recent logs for a service (limit 100)
ssh wolf 'curl -s -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={host=\"<host>\", unit=\"<service>.service\"}" \
  --data-urlencode "limit=100" | jq -r ".data.result[0].values[][1]"'

# Search for errors in service logs
ssh wolf 'curl -s -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={host=\"<host>\", unit=\"<service>.service\"} |= \"error\"" \
  --data-urlencode "limit=50" | jq -r ".data.result[0].values[][1]"'

# Query nginx access logs for specific vhost
ssh wolf 'curl -s -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={host=\"wolf\", unit=\"nginx.service\"} | pattern \`<ip> - <user> [<time>] \"<method> <path> <protocol>\" <status> <size> \"<referer>\" \"<ua>\" <duration> <vhost> <scheme> <upstream>\` | vhost = \"www.kyleondy.com\"" \
  --data-urlencode "limit=100" | jq .'

# Get logs from specific time range (last hour)
ssh wolf 'curl -s -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={host=\"<host>\", unit=\"<service>.service\"}" \
  --data-urlencode "start=$(date -u -d \"1 hour ago\" +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  --data-urlencode "limit=100" | jq .'
```

## Common Failure Patterns

### Stale NFS Mount (bear)

**Symptoms**: Jellyfin/Tdarr can't access /mnt/media, `df -h` hangs on NFS mount

**Cause**: Network interruption, WireGuard reconnection, NFS server restart

**Fix**:

```bash
ssh bear sudo systemctl restart wolf-media.mount
ssh bear ls -la /mnt/media  # Verify mount works
```

### Tdarr Node GPU Access Denied

**Symptoms**: Tdarr node logs show "cannot access /dev/dri/renderD128"

**Cause**: User not in `render` or `video` group

**Fix**: Check NixOS config for `tdarr-node` user groups, verify GPU device permissions

### Service Hit Restart Limit

**Symptoms**: Service shows as "failed" with "start-limit-hit"

**Cause**: Service crashed repeatedly (10 times in 2 minutes)

**Fix**:

```bash
ssh <host> sudo systemctl reset-failed <service>
ssh <host> sudo systemctl start <service>
# Then investigate why it was crashing (check logs)
```

### Alertmanager Not Sending Email

**Symptoms**: Alerts firing in vmalert, but no emails received

**Cause**: SMTP configuration error, wrong server, auth failure

**Fix**:

```bash
# Check alertmanager logs for SMTP errors
ssh wolf journalctl -u alertmanager -n 100 | grep -i smtp

# Verify SMTP config matches email.nix (london.mxroute.com:587)
ssh wolf cat /etc/alertmanager/alertmanager.yml | grep smtp

# Check if sops secrets are loaded
ssh wolf systemctl status alertmanager | grep -i secret
```

### ZFS Pool Degraded

**Symptoms**: `zpool status` shows DEGRADED state, read/write errors

**Cause**: Disk failure, cable issue, controller problem

**Fix**:

```bash
# Check which device is faulted
ssh wolf zpool status -v

# If disk is truly dead, replace it
# ssh wolf zpool replace <pool> <old-device> <new-device>

# If transient error, try online/offline cycle
# ssh wolf zpool offline <pool> <device>
# ssh wolf zpool online <pool> <device>

# Run scrub to check data integrity
ssh wolf zpool scrub <pool>
```

### SABnzbd Not Downloading

**Symptoms**: Queue shows items but no download progress

**Cause**: Usenet provider issue, disk space full, /incomplete not writable

**Fix**:

```bash
# Check disk space
ssh wolf df -h /tiger-pool

# Check SABnzbd logs
ssh wolf journalctl -u sabnzbd -n 100

# Check Usenet provider connectivity (check SABnzbd UI)
# http://wolf:8080/sabnzbd

# Restart SABnzbd
ssh wolf sudo systemctl restart sabnzbd
```

### \*arr Apps Not Importing

**Symptoms**: Downloads complete, but not imported to /tiger-pool/media

**Cause**: Permissions issue, disk space, \*arr not monitoring SABnzbd

**Fix**:

```bash
# Check if files exist in /incomplete
ssh wolf ls -la /tiger-pool/incomplete

# Check *arr logs for import errors
ssh wolf journalctl -u sonarr -n 100 | grep -i import
ssh wolf journalctl -u radarr -n 100 | grep -i import

# Check permissions on media directories
ssh wolf ls -la /tiger-pool/media/{tv,movies}

# Trigger manual import (via UI or API)
```

## Execution Flow

1. **Parse arguments** (if provided, skip triage)
2. **Interactive triage** (if no args): Use `AskUserQuestion` to narrow scope
3. **Run appropriate diagnostic commands** via SSH
4. **Interpret results** and suggest fixes
5. **Offer to run fixes** if clear path forward
6. **Summarize findings** and next steps

## Notes

- All SSH commands assume SSH keys are configured (no password prompts)
- Metric queries return JSON - parse with `jq` for readability
- Loki queries return JSONL - extract log lines with `jq -r`
- Always check WireGuard connectivity before debugging NFS issues
- Check systemd service status before diving into logs
- Use `systemctl --failed` as first step for general health checks
