# Monitoring Stack Documentation

This directory contains the NixOS configuration for a VictoriaMetrics-based monitoring stack with Grafana, Loki, and Alertmanager.

## Architecture Overview

### Server Components (cheetah)

- **VictoriaMetrics**: Time-series database for metrics storage
- **Loki**: Log aggregation system
- **Grafana**: Visualization and dashboarding
- **Alertmanager**: Alert routing and notification
- **vmalert**: Alert rule evaluation

### Agent Components (all hosts)

- **vmagent**: Metrics collection and forwarding
- **promtail**: Log collection and forwarding
- **node_exporter**: System metrics
- **nginx_exporter**: NGINX stub_status metrics
- **nginxlog_exporter**: NGINX access log analytics
- **zfs_exporter**: ZFS filesystem metrics

## Important Conventions

### Label Naming: Use `host` not `instance`

**CRITICAL**: Always use the `host` label instead of `instance` when creating or modifying dashboards.

#### Why?

- `instance` shows technical endpoint addresses like `127.0.0.1:9100` or `127.0.0.1:4040`
- `host` shows friendly hostnames like `cheetah`, `tiger`, `dino`

#### How to Configure

When creating or importing Grafana dashboards:

1. **Template Variables**: Use `host` label for hostname selection

   ```json
   {
     "name": "host",
     "query": "label_values(metric_name, host)"
   }
   ```

2. **Panel Queries**: Filter by `host` not `instance`

   ```promql
   # Good
   node_cpu_seconds_total{host="$host"}

   # Bad - shows IP:port instead of hostname
   node_cpu_seconds_total{instance="$instance"}
   ```

3. **Legend Formatting**: Use `{{host}}` in legend

   ```json
   {
     "legendFormat": "{{host}} - {{device}}"
   }
   ```

#### Applying to Existing Dashboards

When importing dashboards from grafana.com:

1. Download the JSON file
2. Replace `label_values(..., instance)` with `label_values(..., host)`
3. Replace all `instance=~"$variable"` with `host=~"$variable"`
4. Update variable names if needed

Example using `sed`:

```bash
sed -i 's/label_values(\([^,]*\),instance)/label_values(\1,host)/g' dashboard.json
sed -i 's/instance=~"\$\([^"]*\)"/host=~"$\1"/g' dashboard.json
```

Or use `jq` for more precise replacements (see nix/modules/nix_modules/monitoring-stack/dashboards/ for examples).

## SMTP Configuration

### Current Setup

- **Provider**: MXRoute
- **SMTP Server**: `london.mxroute.com:587`
- **From Address**: `monitoring@ondy.org`
- **Recipient**: `kyle@ondy.org`
- **Authentication**: Required (credentials in sops secrets)

### Important Notes

- The SMTP server MUST match the configuration in `nix/modules/hm_modules/terminal/email.nix`
- MXRoute uses server-specific hostnames: `london.mxroute.com`, not `mail.ondy.org`
- Check MX records if changing providers: `dig ondy.org MX +short`

### Testing Email Alerts

After configuration changes:

1. Deploy to cheetah
2. Check alertmanager logs: `ssh cheetah systemctl status alertmanager`
3. Look for SMTP connection errors in logs
4. Verify alerts are firing: `curl http://127.0.0.1:8880/api/v1/alerts` (on cheetah)

## Adding New Dashboards

Grafana dashboards are provisioned via NixOS configuration.

### Step 1: Add Dashboard File

Place the JSON file in `nix/modules/nix_modules/monitoring-stack/dashboards/`:

```bash
cd nix/modules/nix_modules/monitoring-stack/dashboards/
curl -o my-dashboard.json https://grafana.com/api/dashboards/<ID>/revisions/<REV>/download
```

### Step 2: Fix Label References

Update the dashboard to use `host` instead of `instance`:

```bash
# Fix template variables
sed -i 's/label_values(\([^,]*\),instance)/label_values(\1,host)/g' my-dashboard.json

# Fix query filters
sed -i 's/instance=\"\$host\"/host=\"$host"/g' my-dashboard.json
```

### Step 3: Add to Grafana Configuration

Edit `nix/modules/nix_modules/monitoring-stack/grafana.nix`:

```nix
environment.etc."grafana-dashboards/my-dashboard.json" = {
  source = ./dashboards/my-dashboard.json;
  mode = "0644";
};
```

### Step 4: Deploy

```bash
make deploy-rs-all-dry  # Dry run to check
# Review changes, then:
deploy --skip-checks -- .
```

Grafana auto-reloads dashboards every 10 seconds.

## Adding New Exporters

### Step 1: Create NixOS Module

Create `nix/modules/nix_modules/monitoring-stack/my_exporter.nix`:

```nix
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.myExporter;
in
{
  options.systemFoundry.monitoringStack.myExporter = {
    enable = mkEnableOption "my-exporter";
    port = mkOption {
      type = types.port;
      default = 9999;
      description = "Port for my-exporter";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Exporter service configuration here
  };
}
```

### Step 2: Import in Stack

Add to `nix/modules/nix_modules/monitoring-stack/default.nix`:

```nix
imports = [
  # ... existing imports
  ./my_exporter.nix
];
```

### Step 3: Configure vmagent Scraping

In host configuration (e.g., `nix/hosts/cheetah/configuration.nix`):

```nix
vmagent = {
  enable = true;
  scrapeConfigs = [
    # ... existing configs
    {
      job_name = "my_exporter";
      static_configs = [
        {
          targets = [ "127.0.0.1:9999" ];
          labels = {
            host = "cheetah";  # Use 'host' label!
          };
        }
      ];
    }
  ];
};
```

**IMPORTANT**: Always add `host = "<hostname>"` label in scrape configs!

## Troubleshooting

### Dashboard Shows "No data"

1. **Check if metrics exist in VictoriaMetrics**:

   ```bash
   ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/query?query=metric_name" | jq .'
   ```

2. **Verify exporter is running**:

   ```bash
   ssh cheetah systemctl status <exporter-name>
   ```

3. **Check exporter metrics endpoint**:

   ```bash
   ssh cheetah 'curl http://127.0.0.1:<port>/metrics | head -20'
   ```

4. **Verify vmagent is scraping**:

   ```bash
   ssh cheetah 'curl http://127.0.0.1:8429/metrics | grep scrape'
   ```

5. **Check for label mismatches**: Dashboard using `instance` instead of `host`?

### Alerts Not Sending Email

1. **Check alertmanager is running**:

   ```bash
   ssh cheetah systemctl status alertmanager
   ```

2. **Check for SMTP errors in logs**:

   ```bash
   ssh cheetah journalctl -u alertmanager -n 50
   ```

3. **Common errors**:
   - `lookup mail.ondy.org: no such host` → Wrong SMTP server configured
   - `authentication failed` → Check sops secrets are loaded
   - `connection refused` → Check SMTP port (587 for STARTTLS)

4. **Verify alerts are firing**:

   ```bash
   ssh cheetah 'curl http://127.0.0.1:8880/api/v1/alerts | jq .'
   ```

5. **Check Alertmanager has received alerts**:

   ```bash
   ssh cheetah 'curl http://127.0.0.1:9093/api/v2/alerts | jq .'
   ```

### Exporter Permission Issues

Common issue: Exporter can't read log files or access resources.

**Example**: nginxlog-exporter reading `/var/log/nginx/access.log`

1. **Check service user groups**:

   ```bash
   ssh cheetah id nginxlog-exporter
   ```

2. **Verify file permissions**:

   ```bash
   ssh cheetah ls -la /var/log/nginx/
   ```

3. **Add user to appropriate group**:

   ```nix
   users.users.nginxlog-exporter = {
     isSystemUser = true;
     group = "nginxlog-exporter";
     extraGroups = [ "nginx" ];  # Grant read access
   };
   ```

## Authentication & Security

### Bearer Token Auth for Metrics/Logs Ingestion

Remote vmagent/promtail instances authenticate using SHA-256 hashed bearer tokens.

**How it works**:

1. Secrets stored in sops (per host)
2. Systemd service generates SHA-256 hashes at boot
3. Nginx maps validate hashes for authentication
4. Clients send SHA-256(token) as bearer token

**Files**:

- Token generation: Host config systemd service `monitoring-token-hash-generator`
- Nginx validation: `nix/modules/nix_modules/monitoring-stack/default.nix`
- Client config: Host config vmagent `bearerTokenFile`

### vmalert UI Access

Protected by HTTP basic auth at <https://vmalert.apps.ondy.org>

Credentials in sops secret: `vmalert_htpasswd`

## Useful Commands

### Query Metrics Directly

```bash
# Query VictoriaMetrics
ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/query?query=up" | jq .'

# List all metric names
ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/label/__name__/values" | jq .'

# Get label values
ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/label/host/values" | jq .'
```

### Check Alert Status

```bash
# vmalert firing alerts
ssh cheetah 'curl -s http://127.0.0.1:8880/api/v1/alerts | jq .'

# Alertmanager alerts
ssh cheetah 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq .'
```

### Grafana Dashboard Reload

Dashboards auto-reload every 10 seconds. To force reload:

```bash
ssh cheetah systemctl restart grafana
```

## Retention Policy

Configured in `nix/hosts/cheetah/configuration.nix`:

```nix
monitoringStack = {
  retention = {
    metrics = 400;  # days
    logs = 400;     # days
  };
};
```

## NGINX Log Analytics Deep Dive

### Available Prometheus Metrics

The nginxlog-exporter provides these **aggregated** metrics (low cardinality):

**Labels available for filtering:**

- `host` - Server hostname (cheetah, tiger, dino)
- `vhost` - Virtual host/website (<www.kyleondy.com>, grafana.apps.ondy.org, etc.)
- `scheme` - Protocol (http, https)
- `method` - HTTP method (GET, POST, PUT, DELETE)
- `status` - HTTP status code (200, 404, 500, etc.)
- `service` - Always "nginx"

**Metrics exposed:**

```promql
# Request counts
nginx_http_response_count_total{vhost="www.kyleondy.com", status="200"}

# Response sizes in bytes
nginx_http_response_size_bytes{vhost="www.kyleondy.com"}

# Total request time (nginx processing + upstream)
nginx_http_response_time_seconds{vhost="www.kyleondy.com"}

# Backend/upstream response time
nginx_upstream_response_time_seconds{vhost="www.kyleondy.com"}
```

**Example queries:**

```promql
# Requests per second by virtual host
rate(nginx_http_response_count_total[5m])

# 95th percentile response time by site
histogram_quantile(0.95, rate(nginx_http_response_time_seconds_hist_bucket[5m]))

# Error rate by site
rate(nginx_http_response_count_total{status=~"5.."}[5m])
  / rate(nginx_http_response_count_total[5m])

# HTTPS vs HTTP traffic ratio
sum(rate(nginx_http_response_count_total{scheme="https"}[5m]))
  / sum(rate(nginx_http_response_count_total[5m]))

# Backend latency (upstream time)
rate(nginx_upstream_response_time_seconds_sum[5m])
  / rate(nginx_upstream_response_time_seconds_count[5m])
```

### Querying IPs and Detailed Data with Loki

#### Why not in Prometheus?

IP addresses create **extreme cardinality** (one time series per IP). With 10,000 visitors, that's 10,000x more data, which destroys performance.

#### Solution: Use Loki for IP-level analysis

Loki stores the complete raw access logs. You can query IPs, full URLs, referrers, and more:

**Access Loki in Grafana:**

1. Go to Explore
2. Select "Loki" datasource
3. Run LogQL queries

**Example LogQL queries:**

```logql
# All nginx access logs
{job="systemd-journal", unit="nginx.service"}

# Parse log fields
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`

# Filter by specific IP
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | ip = "203.0.113.42"

# Count unique IPs
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | __error__ = ""
  | count by (ip)

# Popular pages on www.kyleondy.com
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | vhost = "www.kyleondy.com"
  | status = "200"
  | count by (path)

# Requests from specific referrer
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | referer =~ "reddit.com"

# User agents (browsers/bots)
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | ua =~ "(?i)bot|crawl|spider"
  | count by (ua)

# Traffic by hour for specific site
sum by (bin) (
  count_over_time(
    {job="systemd-journal", unit="nginx.service"}
      | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
      | vhost = "www.kyleondy.com"
    [1h]
  )
)

# Slow requests (>1 second)
{job="systemd-journal", unit="nginx.service"}
  | pattern `<ip> - <user> [<time>] "<method> <path> <protocol>" <status> <size> "<referer>" "<ua>" <duration> <vhost> <scheme> <upstream>`
  | duration > 1.0
```

### What You CANNOT Track (Without Additional Tools)

These require client-side JavaScript tracking (like Google Analytics, Matomo, Plausible):

- ❌ Geographic location (city/country) - requires GeoIP database
- ❌ Session duration and bounce rate - requires session tracking
- ❌ Screen resolution and device type - requires browser detection
- ❌ JavaScript errors - requires client-side instrumentation
- ❌ Page engagement metrics (scroll depth, time on page) - requires JS events

### Options for Enhanced Analytics

#### Option 1: GoAccess (Server-side, simple)

```bash
# Install GoAccess
# Add to system packages, run as cron job

ssh cheetah 'goaccess /var/log/nginx/access.log \
  --log-format=COMBINED \
  --output=/var/www/stats/index.html \
  --real-time-html'
```

Provides: Top pages, referrers, browsers, OS, geographic data (with GeoIP)

#### Option 2: Matomo/Plausible (Client-side tracking)

Privacy-focused analytics with JavaScript tracking.
Requires: Database, web server, JavaScript snippet on pages

#### Option 3: Extended Loki Analysis

Keep using Loki + custom dashboards for server-side analysis.
Add GeoIP database to map IPs to locations.

### Current Limitations

**What nginx logs CANNOT tell you:**

1. **Actual visitor count** - Can't distinguish unique users vs. bots vs. repeated visits
2. **Geographic location** - IPs are logged but not mapped to locations
3. **Device/browser details** - User-agent is logged but requires parsing
4. **Session analytics** - No concept of sessions/visitors without cookies
5. **Page engagement** - Only knows request was made, not how user interacted

**For true visitor analytics, you need client-side tracking (JavaScript).**

## References

- [VictoriaMetrics Documentation](https://docs.victoriametrics.com/)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)
- [LogQL Documentation](https://grafana.com/docs/loki/latest/query/)
- [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/)
- [Prometheus Exporters](https://prometheus.io/docs/instrumenting/exporters/)
- [prometheus-nginxlog-exporter](https://github.com/martin-helmich/prometheus-nginxlog-exporter)
