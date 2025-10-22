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
- [Best Practices](#best-practices)
- [Examples](#examples)

## Label Naming

### Use `host` not `instance`

**CRITICAL**: Always use the `host` label instead of `instance` when creating or modifying dashboards.

**Why?**

- `instance` shows technical endpoint addresses like `127.0.0.1:9100` or `127.0.0.1:4040`
- `host` shows friendly hostnames like `cheetah`, `tiger`, `dino`

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
   # ✅ Good
   node_cpu_seconds_total{host="$host"}

   # ❌ Bad - shows IP:port instead of hostname
   node_cpu_seconds_total{instance="$instance"}
   ```

3. **Legend Formatting**: Use `{{host}}` in legend

   ```json
   {
     "legendFormat": "{{host}} - {{device}}"
   }
   ```

### Other Important Labels

- `job` - Type of metrics (node, nginx, zfs, etc.)
- `vhost` - Virtual host for nginx metrics (<www.kyleondy.com>, grafana.apps.ondy.org, etc.)
- `pool` - ZFS pool name (storage, scratch, etc.)
- `service` - Systemd service name

## Dashboard Organization

### Folder Structure

Dashboards should be organized into logical folders:

- **System Monitoring** - Host-level metrics (node-exporter, systemd services)
- **Network & Web** - NGINX metrics, traffic analysis
- **Storage** - ZFS pools, disk usage
- **Applications** - Application-specific dashboards (media services, youtube-downloader)
- **Alerting** - Alert status and history

### Naming Conventions

Dashboard titles should follow this pattern:

```text
[Category] - [Specific Component] - [Host (if applicable)]
```

Examples:

- `System - Node Exporter Full`
- `Network - NGINX Log Metrics`
- `Storage - ZFS - Tiger`
- `App - YouTube Downloader - Operational`

## Dashboard Metadata

### Required Fields

Every dashboard JSON must include:

```json
{
  "title": "Dashboard Title",
  "uid": "unique-dashboard-id",
  "tags": ["category", "component"],
  "description": "Brief description of what this dashboard shows",
  "version": 1,
  "id": null,
  "editable": true,
  "graphTooltip": 1,
  "refresh": "30s",
  "schemaVersion": 27,
  "timezone": ""
}
```

### UID Conventions

Dashboard UIDs should be:

- Lowercase with hyphens
- Descriptive and unique
- Related to the dashboard content

Examples:

- `system-overview`
- `nginx-vhost-details`
- `zfs-storage`
- `youtube-downloader-operational`

### Tags

Use consistent tags for easier filtering:

- `system`, `network`, `storage`, `application`
- Component-specific: `nginx`, `zfs`, `node`, `systemd`
- Host-specific: `tiger`, `cheetah`, `dino` (only if dashboard is host-specific)

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

### Step 4: Add to Grafana Configuration

Edit `nix/modules/nix_modules/monitoring-stack/grafana.nix`:

```nix
environment.etc."grafana-dashboards/my-dashboard.json" = {
  source = ./dashboards/my-dashboard.json;
  mode = "0644";
};
```

### Step 5: Deploy

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

## Dashboard Folder Organization

To organize dashboards into folders in Grafana, use the `folderUid` property in provisioning or set folders via the Grafana API.

### Creating Folders via Provisioning

Folders are created automatically when you reference them in dashboard JSON:

```json
{
  "title": "My Dashboard",
  "folderTitle": "System Monitoring",
  "uid": "my-dashboard"
}
```

However, the current provisioning setup uses a flat structure (`foldersFromFilesStructure = false`). To use folders:

1. Create subdirectories in `dashboards/`:

   ```text
   dashboards/
   ├── system/
   │   ├── node-exporter.json
   │   └── systemd-services.json
   ├── network/
   │   ├── nginx-exporter.json
   │   └── nginx-log-metrics.json
   └── storage/
       └── zfs-storage.json
   ```

2. Enable folder structure in `grafana.nix`:

   ```nix
   options = {
     path = "/etc/grafana-dashboards";
     foldersFromFilesStructure = true;
   };
   ```

3. Update provisioning paths to include subdirectories.

## Troubleshooting

### Dashboard Shows "No data"

1. **Check if metrics exist in VictoriaMetrics**:

   ```bash
   ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/query?query=metric_name" | jq .'
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
   ssh cheetah journalctl -u grafana -n 50
   ```

2. **Verify file permissions**: Should be `0644`

3. **Check JSON syntax**: `jq . < dashboard.json`

4. **Force reload**:

   ```bash
   ssh cheetah systemctl restart grafana
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
   ssh cheetah 'curl -s "http://127.0.0.1:8428/api/v1/label/__name__/values" | jq .'
   ```

**Common examples:**

- **ZFS exporter**: `zfs_zpool_*` (old) → `zfs_pool_*` (new), label `poolname` → `pool`
- **Node exporter**: Metric names generally stable, but check label changes
- **NGINX exporter**: Different exporters use different naming schemes

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
# ❌ Bad - doesn't work in VictoriaMetrics
node_systemd_unit_state{name=~".*\\.service"}

# ✅ Good - works in VictoriaMetrics
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
# ❌ WRONG - counts all time series with state="failed" label (even if value=0)
count(node_systemd_unit_state{state="failed"})
# Result: 308 (counts time series, not failed services)

# ✅ CORRECT - counts only services actually in failed state (value=1)
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

## Best Practices

1. **Always use `host` label** for hostname filtering
2. **Include template variables** for filtering (host, pool, service, etc.)
3. **Set appropriate refresh rates** (30s for most dashboards)
4. **Use consistent color schemes** (palette-classic for time series)
5. **Add helpful text panels** with legends, references, or explanations
6. **Test with different time ranges** (1h, 6h, 24h, 7d)
7. **Keep dashboard focused** - Split complex dashboards into multiple focused ones
8. **Document custom queries** with comments in panel descriptions
9. **Use meaningful legend formats** - Include relevant labels
10. **Set y-axis limits** when appropriate to improve readability

## Examples

See existing dashboards for examples:

- `nginx-vhost-details.json` - Good use of template variables and host label
- `zfs-storage.json` - Proper metric naming and gauge panels
- `youtube-downloader-operational.json` - Well-organized multi-panel layout
- `system-overview.json` - Clean, focused dashboard design
