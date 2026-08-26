# Grafana Dashboard Conventions

This document outlines the conventions and best practices for creating and maintaining Grafana dashboards in this monitoring stack.

## Table of Contents

- [Label Naming](#label-naming)
- [Dashboard Organization](#dashboard-organization)
- [Dashboard Metadata](#dashboard-metadata)
- [Panel Configuration](#panel-configuration)
- [Template Variables](#template-variables)
- [Adding New Dashboards](#adding-new-dashboards)
- [Modifying Existing Dashboards](#modifying-existing-dashboards)
- [Troubleshooting](#troubleshooting)
  - [Dashboard Shows "No data"](#dashboard-shows-no-data)
  - [Dashboard Not Updating](#dashboard-not-updating)
  - [Template Variable Shows No Values](#template-variable-shows-no-values)
  - [Exporter Metric Naming Mismatches](#exporter-metric-naming-mismatches)
  - [VictoriaMetrics Regex Quirks](#victoriametrics-regex-quirks)
  - [State-Based Metrics](#state-based-metrics-node_systemd_unit_state)

## Label Naming

### Use `host` not `instance`

**CRITICAL**: Always use the `host` label instead of `instance` when creating or modifying dashboards.

**Why?**

- `instance` shows technical endpoint addresses like `127.0.0.1:9100` or `127.0.0.1:4040`
- `host` shows friendly hostnames like `tiger`, `trex`

**How to Configure:**

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

### Other Important Labels

- `job` - Type of metrics (node, caddy, zfs, etc.)
- `pool` - ZFS pool name (storage, scratch, etc.)
- `service` - Systemd service name
- `name` - UniFi device name on `unpoller_*`, dataset name on `zfs_dataset_*`
- `task` - cogsworth scheduler task, relabelled off the app's own `job`
- `vhost` - the site a Caddy access log line was served for

### An exporter's own labels never win

`honor_labels` is false, so any label the exporter emits that collides with
one the scrape config sets arrives renamed to `exported_<label>`
([Prometheus docs][honor-labels]). A rule written against the original name
matches nothing, silently.

Two live cases:

- cogsworth labels each scheduler task `job`, which is also the scrape's own
  label. `nix/hosts/cogsworth/configuration.nix` relabels it to `task`.
- promtail labels its client series `host` with the Loki address. Nothing
  renames it, so it reads `exported_host`, and `host` stays `tiger`.

Before writing a rule against a label, check what the label is actually
called once the sample has landed:

```bash
ssh tiger 'curl -sG --data-urlencode "query=<metric>" \
  http://127.0.0.1:8428/api/v1/query | jq -c ".data.result[0].metric"'
```

[honor-labels]: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config

### In Loki, select on `unit`, not `job`

The metrics rule above does not carry over to LogQL. promtail ships a
whole journal under one job, so there is no per-service job to select on:

```bash
$ ssh tiger 'curl -s localhost:3100/loki/api/v1/label/job/values' | jq -r '.data[]'
caddy-access
darwin-unified-log
systemd-journal
```

`caddy-access` is the exception, and the only one: it tails files rather than
the journal, one per site, and carries a `vhost` label taken from
`request.host` in the line.

A selector like `{host="tiger",job="jellyfin"}` therefore matches
nothing and the panel sits empty forever. Name the systemd unit
instead:

```logql
# Bad - no such stream, panel is always empty
{host="tiger",job="jellyfin"} |= "FFmpeg exited"

# Good
{host="tiger",unit="jellyfin.service"} |= "FFmpeg exited"
```

Check what is actually there before writing the query:

```bash
ssh tiger 'curl -s localhost:3100/loki/api/v1/label/unit/values' | jq -r '.data[]'
```

### Parse Loki fields at read time, do not label them

A Loki stream is one combination of label values, so labels multiply. The
Caddy access logs carry `vhost` and nothing else off the line: adding `status`
and `method` too would turn 20 streams into roughly 1600. Everything else
comes back out with `| json` in the query:

```logql
sum by (status) (rate({job="caddy-access"} | json status="status" [$__auto]))
```

Fields with a hyphen or an array need bracket form:

```logql
{job="caddy-access"} | json ua="request.headers[\"User-Agent\"][0]"
```

## Dashboard Organization

### Folder Structure

`grafana.nix` sets `foldersFromFilesStructure = true`, so the subdirectory a
dashboard sits in under `dashboards/` becomes its Grafana folder. Adding one
is dropping in a file; there is nothing to register.

Three folders exist:

- `system/` - host-level metrics (node exporter, systemd services)
- `network/` - Caddy
- `applications/` - per-service dashboards (\*arr, jellyfin, cogsworth, media)

### Naming Conventions

Dashboard titles should follow this pattern:

```text
[Specific Component] - [Detail or Host (if applicable)]
```

Examples, from dashboards that exist:

- `Hosts`
- `Storage and Data Safety`
- `Caddy Reverse Proxy`
- `Monitoring Stack Health`

### Every dashboard answers an alert

Each one is the place you land when something fires, and the mapping lives in
the repo `CLAUDE.md`. A dashboard no alert can send you to gets opened once
and then never again: of the eleven that predated this rule, nine went a full
month without a single view.

Adding a dashboard for a subsystem with no alerts means adding the alerts
too.

## Dashboard Metadata

### Required Fields

Every dashboard JSON must include:

```json
{
  "title": "Dashboard Title",
  "uid": "unique-dashboard-id",
  "tags": ["category", "component"],
  "description": "Brief description of what this dashboard shows",
  "id": null
}
```

`id: null` is what provisioning requires; the rest is how we find things
later. Everything else Grafana fills in. The shipped dashboards run
schemaVersion 26 through 38 and refresh anywhere from unset to 1m, so do
not copy those values from another file expecting them to mean something.

### UID Conventions

Dashboard UIDs should be:

- Lowercase with hyphens
- Descriptive and unique
- Related to the dashboard content

Examples:

- `hosts`
- `caddy-overview`
- `storage-data-safety`
- `monitoring-stack`

### Tags

Use consistent tags for easier filtering:

- `system`, `network`, `storage`, `application`
- Component-specific: `caddy`, `zfs`, `node`, `systemd`
- Host-specific: `tiger`, `trex` (only if dashboard is host-specific)

## Panel Configuration

### Panel Titles

- Use clear, descriptive titles
- Capitalize first letter of each major word
- Avoid redundant information (e.g., don't prefix everything with hostname if it's already in a variable)

### Time Series Panels

Default configuration for time series panels:

```json
{
  "type": "timeseries",
  "fieldConfig": {
    "defaults": {
      "custom": {
        "drawStyle": "line",
        "lineWidth": 2,
        "fillOpacity": 10,
        "showPoints": "never",
        "spanNulls": false
      },
      "unit": "appropriate-unit",
      "color": {
        "mode": "palette-classic"
      }
    }
  },
  "options": {
    "legend": {
      "calcs": ["last", "max"],
      "displayMode": "table",
      "placement": "right"
    },
    "tooltip": {
      "mode": "multi"
    }
  }
}
```

### Units

Use appropriate units for metrics:

- **Bytes**: `bytes`, `decbytes` (decimal), `bytes/sec` (throughput)
- **Time**: `s` (seconds), `ms` (milliseconds), `µs` (microseconds)
- **Percentage**: `percentunit` (0-1 range), `percent` (0-100 range)
- **Operations**: `ops`, `iops`, `reqps` (requests per second)
- **Count**: `short` (raw numbers)

### Thresholds

Set meaningful thresholds for alerting visualization:

```json
{
  "thresholds": {
    "mode": "absolute",
    "steps": [
      {
        "color": "green",
        "value": null
      },
      {
        "color": "yellow",
        "value": 70
      },
      {
        "color": "red",
        "value": 85
      }
    ]
  }
}
```

## Template Variables

### Standard Variables

Most dashboards should include a `host` variable:

```json
{
  "name": "host",
  "type": "query",
  "datasource": "VictoriaMetrics",
  "query": "label_values(up, host)",
  "multi": true,
  "includeAll": true,
  "allValue": ".*",
  "refresh": 1,
  "sort": 1
}
```

### Variable Naming

- Use lowercase with underscores: `host`, `pool_name`, `service_name`
- Make variables multi-select when appropriate
- Always set `refresh: 1` (on dashboard load) or `refresh: 2` (on time range change)

## Adding New Dashboards

### Step 1: Create Dashboard File

Place the JSON file in `nix/modules/nix_modules/monitoring-stack/dashboards/`:

```bash
cd nix/modules/nix_modules/monitoring-stack/dashboards/
# Create or download dashboard
```

### Step 2: Fix Label References

Update the dashboard to use `host` instead of `instance`:

```bash
# Fix template variables
sed -i 's/label_values(\([^,]*\),instance)/label_values(\1,host)/g' my-dashboard.json

# Fix query filters
sed -i 's/instance=~"\$\([^"]*\)"/host=~"$\1"/g' my-dashboard.json

# Fix legend format
sed -i 's/{{instance}}/{{host}}/g' my-dashboard.json
```

Or use `jq` for more precise replacements.

### Step 3: Set Dashboard Metadata

Ensure the dashboard has:

- Unique `uid`
- Appropriate `title`
- Relevant `tags`
- Clear `description`
- `id: null` (required for provisioning)

### Step 4: Deploy

```bash
# Dry run to check
make deploy-rs-all-dry

# Deploy
deploy --skip-checks -- .
```

Grafana auto-reloads dashboards every 10 seconds.

## Modifying Existing Dashboards

### Option 1: Edit in Grafana UI (Recommended for Testing)

1. Make changes in Grafana UI
2. Click "Save dashboard"
3. Copy JSON from "Dashboard settings" → "JSON Model"
4. Update the file in `dashboards/` directory
5. Deploy the changes

### Option 2: Edit JSON Directly

1. Edit the JSON file in `dashboards/` directory
2. Validate JSON syntax: `jq . < dashboard.json`
3. Deploy the changes
4. Grafana will reload automatically

### Important Notes

- Always keep `id: null` in dashboard JSON
- Preserve the `uid` to maintain dashboard URLs
- Increment `version` when making significant changes
- Test changes in Grafana UI before committing

## Troubleshooting

### Dashboard Shows "No data"

1. **Check if metrics exist in VictoriaMetrics**:

   ```bash
   ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/query?query=metric_name" | jq .'
   ```

2. **Verify label names**: Ensure using `host` not `instance`

3. **Check time range**: Some metrics may not have historical data

4. **Verify exporter is running**:

   ```bash
   ssh host systemctl status <exporter-name>
   ```

### Dashboard Not Updating

1. **Check provisioning logs**:

   ```bash
   ssh tiger journalctl -u grafana -n 50
   ```

2. **Verify file permissions**: Should be `0644`

3. **Check JSON syntax**: `jq . < dashboard.json`

4. **Force reload**:

   ```bash
   ssh tiger systemctl restart grafana
   ```

### Template Variable Shows No Values

1. **Check metric exists**: Query VictoriaMetrics directly
2. **Verify label name**: Use `host` not `instance`
3. **Check datasource**: Ensure using `VictoriaMetrics`
4. **Test query**: Run the variable query in Grafana Explore

### Exporter Metric Naming Mismatches

When importing dashboards from grafana.com or updating exporters, metric names may change between versions.

**Symptoms:**

- Dashboard shows "No data" despite exporter running
- Template variables show no options
- All panels are empty

**How to diagnose:**

1. **Check what metrics the exporter actually provides**:

   ```bash
   # Check exporter endpoint directly
   ssh host 'curl -s http://127.0.0.1:<exporter-port>/metrics | grep "^metric_prefix" | cut -d"{" -f1 | sort -u'
   ```

2. **Compare with dashboard queries**:

   ```bash
   # Extract metric names from dashboard JSON
   jq '.panels[].targets[].expr' dashboard.json | grep -o 'metric_name[a-z_]*'
   ```

3. **Check VictoriaMetrics for available metrics**:

   ```bash
   ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/label/__name__/values" | jq .'
   ```

**Common examples:**

- **ZFS exporter**: `zfs_zpool_*` (old) → `zfs_pool_*` (new), label `poolname` → `pool`
- **Node exporter**: Metric names generally stable, but check label changes
- **Caddy**: Metrics come from Caddy's own `/metrics` endpoint, not an exporter

**How to fix:**

1. Identify all mismatched metric names in dashboard JSON
2. Use find/replace to update:

   ```bash
   # Update metric names
   sed -i 's/old_metric_name/new_metric_name/g' dashboard.json
   # Update label names
   sed -i 's/old_label/new_label/g' dashboard.json
   ```

3. Verify JSON is still valid: `jq . < dashboard.json`
4. Deploy and test

### VictoriaMetrics Regex Quirks

**Issue**: VictoriaMetrics doesn't handle escaped dots in regex patterns correctly.

**Symptoms:**

- Dashboard shows "No data" despite metrics existing
- Queries work in Prometheus but not VictoriaMetrics
- Pattern like `name=~".*\\.service"` returns 0 results

**Root Cause**: VictoriaMetrics interprets `\\.` differently than Prometheus. Use unescaped `.` instead.

**Solution:**

```bash
# Bad - doesn't work in VictoriaMetrics
node_systemd_unit_state{name=~".*\\.service"}

# Good - works in VictoriaMetrics
node_systemd_unit_state{name=~".*.service"}
```

**Note**: `.` matches any character in regex, not just literal dot. This is usually fine for metric filtering, but be aware of the difference.

**How to fix in dashboard JSON:**

```bash
# Replace escaped dots with unescaped dots
sed -i 's/\\\\\\.service/.service/g' dashboard.json
```

### State-Based Metrics (node_systemd_unit_state)

**Issue**: Some metrics expose multiple time series per resource with state labels, where only one has value `1`.

**How it works**: The `node_systemd_unit_state` metric creates **5 time series per service**:

```promql
node_systemd_unit_state{name="nginx.service",state="active"} = 1
node_systemd_unit_state{name="nginx.service",state="inactive"} = 0
node_systemd_unit_state{name="nginx.service",state="failed"} = 0
node_systemd_unit_state{name="nginx.service",state="activating"} = 0
node_systemd_unit_state{name="nginx.service",state="deactivating"} = 0
```

Only the current state has value `1`, all others have value `0`.

**Common Mistake**: Counting time series instead of actual states:

```promql
# WRONG - counts all time series with state="failed" label (even if value=0)
count(node_systemd_unit_state{state="failed"})
# Result: 308 (counts time series, not failed services)

# CORRECT - counts only services actually in failed state (value=1)
count(node_systemd_unit_state{state="failed"} == 1)
# Result: 0 (no services are failed)
```

**Correct Patterns:**

```promql
# Count total services (unique service names)
count(max by (name, host) (node_systemd_unit_state{name=~".*.service"}))

# Count services in specific state
count(node_systemd_unit_state{name=~".*.service",state="active"} == 1)

# Count by state for pie chart
count by (state) (node_systemd_unit_state{name=~".*.service"} == 1)

# Time series by host and state
count by (host, state) (node_systemd_unit_state{name=~".*.service"} == 1)
```

**When to use this pattern**: Any metric that uses boolean indicator time series for states (systemd units, alerting states, etc.)
