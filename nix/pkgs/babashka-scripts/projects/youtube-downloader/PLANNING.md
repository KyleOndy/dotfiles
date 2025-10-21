# YouTube Downloader Monitoring & Observability Plan

## Overview

This document outlines the complete monitoring and observability strategy for the YouTube downloader service. The service runs as a systemd timer (daily at 4 AM) and integrates with:

- **VictoriaMetrics** - Prometheus-compatible metrics storage
- **Loki** - Structured log aggregation
- **Grafana** - Visualization and alerting
- **Node Exporter** - Metrics exposure via textfile collector

## Available Metrics

### Counters

| Metric Name                 | Description                     | Labels              | Usage                                          |
| --------------------------- | ------------------------------- | ------------------- | ---------------------------------------------- |
| `yt_downloads_total`        | Total channel download attempts | `status`, `channel` | Track success/failure rates per channel        |
| `yt_videos_processed_total` | Individual videos processed     | -                   | Count total video downloads                    |
| `yt_errors_total`           | Errors encountered              | `type`, `channel`   | Error distribution and patterns                |
| `yt_retry_attempts_total`   | Retry attempts                  | `channel`, `reason` | Identify problematic channels/transient issues |

**Counter Label Values:**

- `status`: `success`, `failed`
- `type`: `network`, `rate-limit`, `members-only`, `private`, `copyright`, `unavailable`, `not-found`, `age-restricted`, `geo-blocked`, `extraction`, `unknown`
- `reason`: Error type name (same as `type` values)

### Histograms

| Metric Name                   | Description             | Buckets                         | Labels    | Usage                   |
| ----------------------------- | ----------------------- | ------------------------------- | --------- | ----------------------- |
| `yt_channel_duration_seconds` | Channel processing time | 1, 5, 10, 30, 60, 120, 300, 600 | `channel` | Performance per channel |
| `yt_session_duration_seconds` | Total session duration  | 60, 300, 600, 1200, 1800, 3600  | -         | Overall run time trends |

**Histogram Metrics Generated:**

- `{metric}_bucket{le="X"}` - Cumulative count of observations ≤ X
- `{metric}_sum` - Sum of all observed values
- `{metric}_count` - Total number of observations

### Gauges

| Metric Name             | Description                   | Labels | Usage                                   |
| ----------------------- | ----------------------------- | ------ | --------------------------------------- |
| `yt_skip_list_size`     | Videos in permanent skip list | -      | Monitor permanent failures accumulating |
| `yt_last_run_timestamp` | Unix timestamp of last run    | -      | Service health / staleness detection    |
| `yt_temp_files_count`   | Files in temp directory       | -      | Detect cleanup issues                   |

## Dashboard Specifications

### 1. Operational Overview Dashboard

**Purpose:** High-level health and performance monitoring

**Panels:**

#### Service Health

```promql
# Last run (hours ago) - Single Stat with color thresholds
(time() - yt_last_run_timestamp) / 3600

# Thresholds:
# Green: < 25 hours
# Yellow: 25-48 hours
# Red: > 48 hours
```

#### Success Rate (24h)

```promql
# Gauge showing percentage
sum(rate(yt_downloads_total{status="success"}[24h])) /
sum(rate(yt_downloads_total[24h])) * 100
```

#### Download Activity Timeline

```promql
# Time series graph with stacked areas
sum by(status) (increase(yt_downloads_total[1h]))
```

#### Videos Processed Today

```promql
# Single stat
increase(yt_videos_processed_total[24h])
```

#### Active Channels (7d)

```promql
# Single stat
count(count by(channel) (yt_downloads_total))
```

#### Average Session Duration

```promql
# Time series with percentiles
histogram_quantile(0.50, rate(yt_session_duration_seconds_bucket[24h]))
histogram_quantile(0.95, rate(yt_session_duration_seconds_bucket[24h]))
histogram_quantile(0.99, rate(yt_session_duration_seconds_bucket[24h]))
```

#### Channel Success Heatmap

```promql
# Heatmap visualization
sum by(channel, status) (increase(yt_downloads_total[6h]))
```

### 2. Error Analysis Dashboard

**Purpose:** Deep dive into failures and problematic patterns

**Panels:**

#### Error Type Distribution (24h)

```promql
# Pie chart
sum by(type) (increase(yt_errors_total[24h]))
```

#### Error Rate Over Time

```promql
# Time series with stacked areas by error type
sum by(type) (rate(yt_errors_total[5m]))
```

#### Top 10 Problematic Channels

```promql
# Table sorted by error count
topk(10, sum by(channel) (increase(yt_errors_total[7d])))
```

#### Channel Error Breakdown

```promql
# Grouped bar chart
sum by(channel, type) (increase(yt_errors_total[24h]))
```

#### Retry Attempts by Reason

```promql
# Time series stacked by reason
sum by(reason) (rate(yt_retry_attempts_total[5m]))
```

#### Retry Success Rate

```promql
# Calculate how often retries eventually succeed
# Compare retry attempts to final failures
(sum(rate(yt_retry_attempts_total[24h])) -
 sum(rate(yt_downloads_total{status="failed"}[24h]))) /
sum(rate(yt_retry_attempts_total[24h])) * 100
```

#### Skip List Growth

```promql
# Time series showing permanent failures accumulating
yt_skip_list_size
```

#### Recent Errors (Table)

```logql
# LogQL query for Loki logs panel
{job="youtube-downloader"} |= "ERROR" | json | line_format "{{.timestamp}} [{{.channel}}] {{.error_type}}: {{.error_message}}"
```

### 3. Performance Dashboard

**Purpose:** Optimize processing times and resource usage

**Panels:**

#### Channel Processing Times (P95)

```promql
# Bar chart comparing channels
topk(10,
  histogram_quantile(0.95,
    sum by(channel, le) (rate(yt_channel_duration_seconds_bucket[7d]))
  )
)
```

#### Processing Time Distribution

```promql
# Heatmap showing duration distribution
sum by(le) (increase(yt_channel_duration_seconds_bucket[24h]))
```

#### Download Velocity

```promql
# Videos per hour during active sessions
rate(yt_videos_processed_total[5m]) * 3600
```

#### Efficiency Ratio

```promql
# Successful downloads per total attempts
sum(rate(yt_downloads_total{status="success"}[24h])) /
sum(rate(yt_downloads_total[24h]))
```

#### Temp Files Monitoring

```promql
# Time series showing temp directory growth
yt_temp_files_count
```

#### Session Duration Trends

```promql
# Time series showing average session length over time
rate(yt_session_duration_seconds_sum[1h]) /
rate(yt_session_duration_seconds_count[1h])
```

#### Time Budget Analysis

```promql
# Show if sessions are getting longer
deriv(yt_session_duration_seconds_sum[7d])
```

### 4. Channel-Specific Dashboard

**Purpose:** Detailed analysis of individual channels

**Dashboard Variables:**

- `$channel` - Template variable populated from `label_values(yt_downloads_total, channel)`

**Panels:**

#### Channel Health Score

```promql
# Composite metric (0-100)
# Formula: (success_rate * 0.6) + (speed_score * 0.2) + (reliability_score * 0.2)

# Success rate component (60% weight)
(sum(rate(yt_downloads_total{status="success",channel="$channel"}[7d])) /
 sum(rate(yt_downloads_total{channel="$channel"}[7d])) * 60)
+
# Speed score component (20% weight) - inverse of P95 duration normalized
(20 - min(20,
  histogram_quantile(0.95,
    rate(yt_channel_duration_seconds_bucket{channel="$channel"}[7d])
  ) / 30 * 20
))
+
# Reliability score (20% weight) - inverse of retry rate
(20 - min(20,
  sum(rate(yt_retry_attempts_total{channel="$channel"}[7d])) * 100
))
```

#### Download Success Timeline

```promql
# Time series with success/failure
sum by(status) (increase(yt_downloads_total{channel="$channel"}[1h]))
```

#### Average Processing Time

```promql
# Time series with moving average
avg_over_time(
  (rate(yt_channel_duration_seconds_sum{channel="$channel"}[5m]) /
   rate(yt_channel_duration_seconds_count{channel="$channel"}[5m])
  )[1h:5m]
)
```

#### Error Pattern Analysis

```promql
# Pie chart of error types for this channel
sum by(type) (increase(yt_errors_total{channel="$channel"}[30d]))
```

#### Recent Activity Log

```logql
# LogQL for logs panel
{job="youtube-downloader"} | json | channel="$channel" | line_format "{{.timestamp}} [{{.level}}] {{.message}}"
```

#### Videos Downloaded (30d)

```promql
# Estimate based on successful downloads
# Note: This is approximate as we track channel attempts, not individual videos
sum(increase(yt_downloads_total{channel="$channel",status="success"}[30d])) * 5
# Assuming average ~5 videos per successful session (adjust based on max_videos config)
```

### 5. Alert Dashboard

**Purpose:** Visual representation of alert states and thresholds

**Panels:**

#### Active Alerts

```promql
# Table showing which alerts are firing
ALERTS{alertname=~"YT.*"}
```

#### Service Staleness Indicator

```promql
# Visual indicator if service hasn't run recently
(time() - yt_last_run_timestamp) > 172800  # 48 hours
```

#### Error Rate Threshold

```promql
# Show current error rate vs threshold (20%)
sum(rate(yt_downloads_total{status="failed"}[1h])) /
sum(rate(yt_downloads_total[1h])) * 100
```

#### Critical Channels

```promql
# Channels with 3+ consecutive failures
# (Requires recording rule or external calculation)
```

## Alert Definitions

### Critical Alerts

#### Service Not Running

```yaml
alert: YTDownloaderStale
expr: (time() - yt_last_run_timestamp) > 172800 # 48 hours
for: 1m
labels:
  severity: critical
  service: youtube-downloader
annotations:
  summary: "YouTube downloader has not run in {{ $value | humanizeDuration }}"
  description: "Last successful run was {{ $value | humanizeDuration }} ago. Expected daily runs."
```

#### High Failure Rate

```yaml
alert: YTDownloaderHighFailureRate
expr: |
  sum(rate(yt_downloads_total{status="failed"}[1h])) /
  sum(rate(yt_downloads_total[1h])) > 0.3
for: 5m
labels:
  severity: critical
  service: youtube-downloader
annotations:
  summary: "YouTube downloader failure rate is {{ $value | humanizePercentage }}"
  description: "More than 30% of channel downloads are failing."
```

### Warning Alerts

#### Rate Limiting Detected

```yaml
alert: YTDownloaderRateLimited
expr: sum(increase(yt_errors_total{type="rate-limit"}[5m])) > 2
for: 1m
labels:
  severity: warning
  service: youtube-downloader
annotations:
  summary: "YouTube rate limiting detected"
  description: "{{ $value }} rate limit errors in the last 5 minutes. Service may be throttled."
```

#### Long Running Session

```yaml
alert: YTDownloaderLongSession
expr: |
  histogram_quantile(0.95,
    rate(yt_session_duration_seconds_bucket[1h])
  ) > 7200  # 2 hours
for: 5m
labels:
  severity: warning
  service: youtube-downloader
annotations:
  summary: "YouTube downloader sessions taking longer than expected"
  description: "P95 session duration is {{ $value | humanizeDuration }}, which may indicate performance issues."
```

#### Skip List Growing Rapidly

```yaml
alert: YTDownloaderSkipListGrowth
expr: |
  increase(yt_skip_list_size[24h]) > 20
for: 1m
labels:
  severity: warning
  service: youtube-downloader
annotations:
  summary: "Skip list growing rapidly"
  description: "{{ $value }} new videos added to permanent skip list in 24h. Content may be becoming unavailable."
```

#### Temp Files Not Cleaned

```yaml
alert: YTDownloaderTempFilesAccumulating
expr: yt_temp_files_count > 100
for: 30m
labels:
  severity: warning
  service: youtube-downloader
annotations:
  summary: "Temp directory has {{ $value }} files"
  description: "Temp directory may not be cleaning up properly. Check disk space and move operations."
```

### Info Alerts

#### Channel Blackout

```yaml
alert: YTDownloaderChannelBlackout
expr: |
  sum by(channel) (increase(yt_downloads_total{status="failed"}[72h])) >= 3
  AND
  sum by(channel) (increase(yt_downloads_total{status="success"}[72h])) == 0
for: 1h
labels:
  severity: info
  service: youtube-downloader
annotations:
  summary: "Channel {{ $labels.channel }} failing consistently"
  description: "Channel has failed 3+ times in 72 hours with no successes. May need investigation."
```

#### Excessive Retries

```yaml
alert: YTDownloaderExcessiveRetries
expr: |
  sum(rate(yt_retry_attempts_total[1h])) /
  sum(rate(yt_downloads_total[1h])) > 0.5
for: 10m
labels:
  severity: info
  service: youtube-downloader
annotations:
  summary: "High retry rate detected"
  description: "More than 50% of operations requiring retries. May indicate transient issues or anti-bot measures."
```

## LogQL Query Library

### Error Pattern Detection

```logql
# Find all errors with context
{job="youtube-downloader"}
  | json
  | level="ERROR"
  | line_format "{{.timestamp}} [{{.channel}}] {{.error_type}}: {{.error_message}}"
```

### Download Activity Stream

```logql
# Real-time feed of what's being downloaded
{job="youtube-downloader"}
  |~ "Downloading:|Processing channel|succeeded"
  | json
  | line_format "{{.timestamp}} - {{.message}} ({{.channel}})"
```

### Channel Processing Timeline

```logql
# Timeline of all channel processing events
{job="youtube-downloader"}
  | json
  | channel!=""
  | line_format "{{.timestamp}} [{{.level}}] {{.channel}}: {{.message}}"
```

### Retry Analysis

```logql
# See what's being retried and why
{job="youtube-downloader"}
  |= "Retrying"
  | json
  | line_format "{{.timestamp}} - {{.channel}} retry #{{.attempt}}: {{.reason}}"
```

### Error Correlation

```logql
# Find errors and their stack traces
{job="youtube-downloader"}
  | json
  | level="ERROR"
  | exception!=""
  | line_format "{{.exception}}: {{.exception_message}}\n{{.stack_trace}}"
```

### Session Summary

```logql
# Extract session start/end for duration calculation
{job="youtube-downloader"}
  |~ "Starting download session|Download session completed"
  | json
  | line_format "{{.timestamp}}: {{.message}} (channels={{.channels}}, successful={{.successful}}, failed={{.failed}})"
```

### Performance Insights

```logql
# Extract duration information from logs
{job="youtube-downloader"}
  |= "duration_seconds"
  | json
  | line_format "{{.channel}}: {{.duration_seconds}}s"
```

## Grafana Setup Instructions

### Data Source Configuration

1. **VictoriaMetrics Data Source**
   - Type: Prometheus
   - URL: `http://victoria-metrics:8428`
   - Access: Server (default)

2. **Loki Data Source**
   - Type: Loki
   - URL: `http://loki:3100`
   - Access: Server (default)

### Dashboard Import Process

1. Create new dashboard in Grafana
2. Set time range to "Last 7 days" (adjustable)
3. Configure template variables if needed (e.g., `$channel`)
4. Add panels using PromQL/LogQL queries above
5. Configure visualization types:
   - **Time series** - Line graphs, area charts
   - **Stat** - Single value displays
   - **Gauge** - Percentage indicators
   - **Bar chart** - Comparative metrics
   - **Table** - Detailed breakdowns
   - **Pie chart** - Distribution visualization
   - **Heatmap** - Time-based distributions
   - **Logs** - LogQL panel for log streams

### Panel Configuration Recommendations

**Color Schemes:**

- Success metrics: Green (`#73BF69`)
- Warning states: Yellow (`#FADE2A`)
- Error states: Red (`#F2495C`)
- Neutral metrics: Blue (`#5794F2`)

**Thresholds:**

- Success rate: >90% green, 70-90% yellow, <70% red
- Session duration: <30min green, 30-60min yellow, >60min red
- Error rate: <10% green, 10-20% yellow, >20% red
- Time since last run: <25h green, 25-48h yellow, >48h red

### Dashboard Layout

**Operational Overview Layout:**

```
Row 1: [Service Health] [Success Rate 24h] [Videos Today] [Active Channels]
Row 2: [Download Activity Timeline - Full Width]
Row 3: [Session Duration Percentiles - Full Width]
Row 4: [Channel Success Heatmap - Full Width]
```

**Error Analysis Layout:**

```
Row 1: [Error Rate] [Retry Success Rate] [Skip List Size]
Row 2: [Error Type Distribution Pie] [Error Rate Over Time]
Row 3: [Top 10 Problematic Channels Table - Full Width]
Row 4: [Recent Error Logs - Full Width]
```

## Troubleshooting Guide

### Metric Pattern Analysis

#### Pattern: High error rate with mostly `network` type

**Diagnosis:** Transient network issues or DNS problems
**Action:** Check network connectivity, DNS resolution, and upstream service status

#### Pattern: Multiple `rate-limit` errors in short period

**Diagnosis:** YouTube API/scraping rate limiting triggered
**Action:** Review download frequency, implement longer delays, check for IP blocks

#### Pattern: Skip list growing with `unavailable`/`private` types

**Diagnosis:** Channel content being deleted or made private
**Action:** Normal operation - review skip list periodically to remove channels with excessive permanent failures

#### Pattern: Long session durations (>2 hours)

**Diagnosis:** Large playlists, slow network, or hung processes
**Action:** Check temp directory for stuck downloads, review yt-dlp logs, consider timeout adjustments

#### Pattern: No metrics updates for >48 hours

**Diagnosis:** Systemd timer not firing or service failing to start
**Action:** Check `systemctl status youtube-downloader.timer` and journal logs

### Log Correlation Examples

**Finding the root cause of a failure:**

```logql
# Step 1: Find the error
{job="youtube-downloader"} | json | level="ERROR" | channel="@problematic-channel"

# Step 2: Get surrounding context
{job="youtube-downloader"} | json | channel="@problematic-channel"

# Step 3: Look for retry attempts
{job="youtube-downloader"} |= "Retrying" | json | channel="@problematic-channel"
```

**Tracking a specific session:**

```logql
# Find session ID or timestamp, then filter
{job="youtube-downloader"}
  | json
  | timestamp>="2025-01-20T04:00:00Z"
  | timestamp<"2025-01-20T05:00:00Z"
```

## Future Enhancements

### Additional Metrics to Consider

1. **Video Size Metrics**
   - Average file size per channel
   - Total bandwidth consumed
   - Storage efficiency (compressed vs raw)

2. **Content Freshness**
   - Days since new content from each channel
   - Upload frequency detection
   - Content velocity trends

3. **Quality Metrics**
   - Resolution distribution (1080p, 720p, etc.)
   - Format preferences (mp4, webm, mkv)
   - Audio quality metrics

4. **Network Performance**
   - Download speed histogram
   - Network retry counts
   - DNS lookup times

5. **Resource Usage**
   - CPU usage during sessions
   - Memory consumption
   - Disk I/O rates

### Dashboard Evolution Ideas

1. **Predictive Analytics**
   - Forecast storage requirements
   - Predict channel activity patterns
   - Anomaly detection on download patterns

2. **Comparative Analysis**
   - Week-over-week trends
   - Month-over-month growth
   - Channel comparison matrices

3. **Cost Analysis**
   - Storage costs trending
   - Bandwidth usage costs
   - Compute time efficiency

4. **Content Insights**
   - Topic clustering (if metadata available)
   - Upload schedule patterns
   - Content type distribution

### Integration Opportunities

1. **Alertmanager Integration**
   - Route alerts to appropriate channels (email, Slack, PagerDuty)
   - Alert aggregation and deduplication
   - Silence management

2. **External Status Page**
   - Public-facing service status
   - Historical uptime tracking
   - Incident timeline

3. **Automated Remediation**
   - Trigger channel config updates based on persistent failures
   - Automatic cleanup of old skip list entries
   - Dynamic retry strategy adjustment

4. **Machine Learning**
   - Predict which channels will fail
   - Optimize download ordering
   - Detect content availability patterns

## Recording Rules

For better query performance, consider adding these recording rules to VictoriaMetrics:

```yaml
# Success rate by channel (1h window)
- record: yt:channel_success_rate:1h
  expr: |
    sum by(channel) (rate(yt_downloads_total{status="success"}[1h])) /
    sum by(channel) (rate(yt_downloads_total[1h]))

# P95 channel duration (1h window)
- record: yt:channel_duration_p95:1h
  expr: |
    histogram_quantile(0.95,
      sum by(channel, le) (rate(yt_channel_duration_seconds_bucket[1h]))
    )

# Error rate by type (5m window)
- record: yt:error_rate:5m
  expr: |
    sum by(type) (rate(yt_errors_total[5m]))

# Total videos per day
- record: yt:videos_processed:1d
  expr: |
    increase(yt_videos_processed_total[1d])
```

## Best Practices

1. **Retention Policies**
   - Keep metrics for at least 30 days for trend analysis
   - Retain logs for 14 days minimum
   - Archive important logs to object storage

2. **Alert Tuning**
   - Start with conservative thresholds
   - Tune based on actual patterns after 1-2 weeks
   - Use `for` clauses to avoid flapping alerts

3. **Dashboard Maintenance**
   - Review dashboards monthly
   - Remove unused panels
   - Update queries as metrics evolve
   - Document dashboard purpose and audience

4. **Performance Optimization**
   - Use recording rules for expensive queries
   - Set appropriate refresh intervals (30s-5m)
   - Limit time ranges for complex visualizations
   - Use template variables for channel filtering

5. **Security**
   - Restrict Grafana access appropriately
   - Don't expose sensitive channel information in public dashboards
   - Rotate API tokens regularly
   - Monitor for metric scraping abuse

---

**Document Version:** 1.0
**Last Updated:** 2025-01-21
**Maintained By:** Kyle
**Related Files:**

- `src/youtube_downloader/observability.clj` - Metric definitions
- `../../shared/src/common/metrics.clj` - Metrics library
- `../../shared/src/common/logging.clj` - Logging library
- `../../shared/src/common/metrics_textfile.clj` - Textfile collector integration
