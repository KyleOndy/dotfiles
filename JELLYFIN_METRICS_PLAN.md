# Jellyfin Prometheus Metrics Integration Plan

## Executive Summary

This document outlines the implementation plan for integrating Jellyfin metrics from the DMZ instance into the existing Grafana monitoring stack at grafana.apps.ondy.org. The solution will use a custom Nix package for the Prometheus exporter, deployed on the DMZ host, with comprehensive user analytics dashboards and alerting.

## Architecture Overview

```text
┌─────────────────────┐
│   DMZ Jellyfin      │
│  jellyfin.apps.dmz  │
│                     │
│  ┌───────────────┐  │
│  │   Jellyfin    │  │
│  │   Service     │  │
│  └───────┬───────┘  │
│          │ API      │
│  ┌───────▼───────┐  │
│  │   Jellyfin    │  │
│  │   Exporter    │  │
│  │  (Port 9594)  │  │
│  └───────┬───────┘  │
└──────────┼──────────┘
           │ Metrics
           │
┌──────────▼──────────┐
│   Monitoring Host   │
│      (tiger)        │
│                     │
│  ┌───────────────┐  │
│  │   vmagent     │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │VictoriaMetrics│  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │    Grafana    │  │
│  │ grafana.apps  │  │
│  └───────────────┘  │
└─────────────────────┘
```

## Implementation Details

### Phase 1: Nix Package Creation

#### 1.1 Jellyfin Exporter Package (`nix/pkgs/jellyfin-exporter/default.nix`)

```nix
{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "jellyfin-prometheus-exporter";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "StefanAbl";
    repo = "jellyfin-prometheus-exporter";
    rev = "v${version}";
    sha256 = ""; # To be filled after first build attempt
  };

  vendorSha256 = ""; # To be filled

  meta = with lib; {
    description = "Prometheus exporter for Jellyfin metrics";
    homepage = "https://github.com/StefanAbl/jellyfin-prometheus-exporter";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
```

### Phase 2: NixOS Module Development

#### 2.1 Exporter Module (`nix/modules/nix_modules/monitoring-stack/jellyfin_exporter.nix`)

```nix
{ lib, pkgs, config, ... }:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.jellyfinExporter;
in
{
  options.systemFoundry.monitoringStack.jellyfinExporter = {
    enable = mkEnableOption "Jellyfin Prometheus exporter";

    port = mkOption {
      type = types.port;
      default = 9594;
      description = "Port for metrics endpoint";
    };

    jellyfinUrl = mkOption {
      type = types.str;
      description = "Jellyfin server URL";
      example = "http://localhost:8096";
    };

    tokenFile = mkOption {
      type = types.path;
      description = "Path to file containing Jellyfin API token";
    };

    extraCollectors = mkOption {
      type = types.listOf types.str;
      default = [ "activity" "library" "sessions" ];
      description = "Additional collectors to enable";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.jellyfin-exporter = {
      description = "Jellyfin Prometheus Exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "jellyfin.service" ];

      serviceConfig = {
        Type = "simple";
        User = "jellyfin-exporter";
        Group = "jellyfin-exporter";
        ExecStart = ''
          ${pkgs.jellyfin-exporter}/bin/jellyfin-exporter \
            --jellyfin.address=${cfg.jellyfinUrl} \
            --jellyfin.token=$(cat ${cfg.tokenFile}) \
            --web.listen-address=:${toString cfg.port} \
            ${concatMapStringsSep " " (c: "--collector.${c}") cfg.extraCollectors}
        '';
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    users.users.jellyfin-exporter = {
      isSystemUser = true;
      group = "jellyfin-exporter";
      description = "Jellyfin exporter service user";
    };

    users.groups.jellyfin-exporter = { };
  };
}
```

### Phase 3: Dashboard Development

#### 3.1 Service Health Dashboard

**File**: `nix/modules/nix_modules/monitoring-stack/dashboards/jellyfin-service-health.json`

**Key Panels**:

- Service uptime gauge
- API response time graph
- CPU usage by Jellyfin process
- Memory consumption
- Disk I/O rates
- Network throughput
- Error rate trends
- Version information

**Metrics Used**:

- `jellyfin_up` - Service availability
- `jellyfin_api_response_seconds` - API latency
- `process_cpu_seconds_total{job="jellyfin"}` - CPU usage
- `process_resident_memory_bytes{job="jellyfin"}` - Memory usage

#### 3.2 Media Library Analytics Dashboard

**File**: `nix/modules/nix_modules/monitoring-stack/dashboards/jellyfin-media-library.json`

**Key Panels**:

- Total items by media type (pie chart)
- Library growth over time (line graph)
- Storage usage by library (bar chart)
- Recently added items (table)
- Codec distribution (pie chart)
- Resolution distribution (bar chart)
- Missing metadata count

**Metrics Used**:

- `jellyfin_library_items_total{type="movie"}` - Movie count
- `jellyfin_library_items_total{type="episode"}` - Episode count
- `jellyfin_library_items_total{type="audio"}` - Music count
- `jellyfin_library_size_bytes` - Storage per library
- `jellyfin_library_scan_duration_seconds` - Scan performance

#### 3.3 User Activity & Playback Dashboard

**File**: `nix/modules/nix_modules/monitoring-stack/dashboards/jellyfin-user-activity.json`

**Key Panels**:

- Active users counter
- Current playback sessions
- User activity heatmap
- Top watched content (table)
- Playback by type (direct/transcode)
- Bandwidth usage graph
- Client types distribution
- Geographic map (if GeoIP enabled)
- Peak usage hours

**Metrics Used**:

- `jellyfin_active_users` - Current active users
- `jellyfin_sessions_total` - Total sessions
- `jellyfin_playback_total{type="directplay"}` - Direct plays
- `jellyfin_playback_total{type="transcode"}` - Transcodes
- `jellyfin_bandwidth_bytes_per_second` - Bandwidth usage
- `jellyfin_user_watch_time_seconds` - Watch time per user

#### 3.4 Transcoding Performance Dashboard

**File**: `nix/modules/nix_modules/monitoring-stack/dashboards/jellyfin-transcoding.json`

**Key Panels**:

- Active transcodes gauge
- Transcode queue length
- Hardware acceleration status
- Transcode reasons breakdown
- CPU usage during transcoding
- GPU usage (if available)
- Transcode failure rate
- Average transcode speed
- Codec conversion matrix

**Metrics Used**:

- `jellyfin_transcode_active` - Active transcodes
- `jellyfin_transcode_queue_length` - Queue size
- `jellyfin_transcode_hw_acceleration` - HW accel status
- `jellyfin_transcode_failures_total` - Failed transcodes
- `jellyfin_transcode_speed_ratio` - Transcode speed

### Phase 4: Alert Rules Configuration

#### 4.1 Critical Alerts

```yaml
- alert: JellyfinDown
  expr: jellyfin_up == 0
  for: 5m
  labels:
    severity: critical
    service: jellyfin
  annotations:
    summary: "Jellyfin service is down on {{ $labels.instance }}"
    description: "Jellyfin has been unavailable for 5 minutes"

- alert: JellyfinAPIUnresponsive
  expr: jellyfin_api_response_seconds > 10
  for: 5m
  labels:
    severity: critical
    service: jellyfin
  annotations:
    summary: "Jellyfin API is unresponsive"
    description: "API response time exceeds 10 seconds"

- alert: JellyfinHighTranscodeFailureRate
  expr: |
    rate(jellyfin_transcode_failures_total[5m]) /
    rate(jellyfin_transcode_total[5m]) > 0.3
  for: 10m
  labels:
    severity: critical
    service: jellyfin
  annotations:
    summary: "High transcode failure rate ({{ $value | humanizePercentage }})"
    description: "More than 30% of transcodes are failing"
```

#### 4.2 Warning Alerts

```yaml
- alert: JellyfinHighCPUUsage
  expr: |
    rate(process_cpu_seconds_total{job="jellyfin"}[5m]) > 0.8
  for: 15m
  labels:
    severity: warning
    service: jellyfin
  annotations:
    summary: "High CPU usage by Jellyfin"
    description: "Jellyfin CPU usage above 80% for 15 minutes"

- alert: JellyfinMemoryPressure
  expr: |
    process_resident_memory_bytes{job="jellyfin"} /
    node_memory_MemTotal_bytes > 0.5
  for: 10m
  labels:
    severity: warning
    service: jellyfin
  annotations:
    summary: "Jellyfin using significant memory"
    description: "Jellyfin is using {{ $value | humanizePercentage }} of system memory"

- alert: JellyfinLibraryScanFailed
  expr: jellyfin_library_scan_failures_total > 0
  for: 5m
  labels:
    severity: warning
    service: jellyfin
  annotations:
    summary: "Library scan failures detected"
    description: "{{ $value }} library scan failures in the last 5 minutes"
```

#### 4.3 Informational Alerts

```yaml
- alert: JellyfinNewUserRegistration
  expr: increase(jellyfin_users_total[1h]) > 0
  labels:
    severity: info
    service: jellyfin
  annotations:
    summary: "New user registration"
    description: "{{ $value }} new user(s) registered in the last hour"

- alert: JellyfinLargeLibraryAddition
  expr: increase(jellyfin_library_items_total[1h]) > 100
  labels:
    severity: info
    service: jellyfin
  annotations:
    summary: "Large library addition"
    description: "{{ $value }} items added to library in the last hour"
```

### Phase 5: Host Configuration Updates

#### 5.1 DMZ Host Configuration

Add to the DMZ Jellyfin host configuration:

```nix
{
  # Enable Jellyfin metrics exporter
  systemFoundry.monitoringStack.jellyfinExporter = {
    enable = true;
    jellyfinUrl = "http://localhost:8096";
    tokenFile = config.sops.secrets.jellyfin_api_token.path;
    extraCollectors = [ "activity" "library" "sessions" "playback" ];
  };

  # Add vmagent scrape config
  systemFoundry.monitoringStack.vmagent.scrapeConfigs = [
    {
      job_name = "jellyfin";
      static_configs = [
        {
          targets = [ "127.0.0.1:9594" ];
          labels = {
            instance = "jellyfin-dmz";
          };
        }
      ];
    }
  ];

  # Ensure API token secret is available
  sops.secrets.jellyfin_api_token = {
    owner = "jellyfin-exporter";
    group = "jellyfin-exporter";
  };
}
```

### Phase 6: Grafana Configuration Updates

#### 6.1 Dashboard Provisioning

Update `nix/modules/nix_modules/monitoring-stack/grafana.nix`:

```nix
environment.etc."grafana-dashboards/jellyfin-service-health.json" = {
  source = ./dashboards/jellyfin-service-health.json;
  mode = "0644";
};

environment.etc."grafana-dashboards/jellyfin-media-library.json" = {
  source = ./dashboards/jellyfin-media-library.json;
  mode = "0644";
};

environment.etc."grafana-dashboards/jellyfin-user-activity.json" = {
  source = ./dashboards/jellyfin-user-activity.json;
  mode = "0644";
};

environment.etc."grafana-dashboards/jellyfin-transcoding.json" = {
  source = ./dashboards/jellyfin-transcoding.json;
  mode = "0644";
};
```

## Security Considerations

### API Token Management

- Store Jellyfin API token in sops-nix secrets
- Token should have read-only permissions
- Rotate tokens periodically

### Network Security

- Metrics endpoint should only be accessible from monitoring infrastructure
- Consider using firewall rules to restrict access
- Use internal network for metrics collection where possible

### Data Privacy

- Avoid exposing PII in metric labels
- Aggregate user data where appropriate
- Consider GDPR compliance for user activity metrics

## Testing Plan

### Unit Testing

1. Verify exporter package builds correctly
2. Test systemd service starts and runs
3. Validate metrics endpoint responds

### Integration Testing

1. Confirm metrics flow from exporter to vmagent
2. Verify data appears in VictoriaMetrics
3. Test dashboard queries return data
4. Validate alert rules evaluate correctly

### Load Testing

1. Simulate high user activity
2. Test transcoding under load
3. Verify metrics collection doesn't impact Jellyfin performance

## Rollout Plan

### Phase 1: Development Environment

1. Deploy exporter to test DMZ instance
2. Configure basic dashboards
3. Validate metrics collection

### Phase 2: Staging

1. Deploy to staging environment
2. Run for 1 week to collect baseline metrics
3. Tune alert thresholds based on observed patterns

### Phase 3: Production

1. Deploy during maintenance window
2. Monitor for 24 hours
3. Enable alerts gradually

## Maintenance Considerations

### Regular Tasks

- Review and update alert thresholds monthly
- Check for exporter updates quarterly
- Audit API token permissions annually
- Archive old metrics data per retention policy

### Troubleshooting Guide

#### Exporter Not Collecting Metrics

1. Check systemd service status: `systemctl status jellyfin-exporter`
2. Verify API token is valid
3. Test Jellyfin API endpoint manually
4. Check network connectivity

#### Missing Metrics in Grafana

1. Verify vmagent scrape config
2. Check VictoriaMetrics for data
3. Test Prometheus queries directly
4. Review Grafana datasource configuration

#### High Resource Usage

1. Reduce scrape frequency if needed
2. Disable unnecessary collectors
3. Optimize dashboard queries
4. Consider sampling for high-cardinality metrics

## Success Metrics

### Technical Success

- 99.9% uptime for metrics collection
- < 1% CPU overhead from exporter
- < 100MB memory usage by exporter
- < 5 second dashboard load times

### Business Success

- Reduce unplanned Jellyfin downtime by 50%
- Improve transcoding efficiency by 20%
- Identify and resolve performance issues before user reports
- Data-driven capacity planning for media storage

## Appendix A: Useful Jellyfin API Endpoints

- `/System/Info` - System information
- `/Sessions` - Active sessions
- `/Items/Counts` - Library item counts
- `/System/ActivityLog/Entries` - Activity log
- `/Playback/BitrateTest` - Bandwidth testing
- `/Users` - User information
- `/System/Endpoint` - API endpoints

## Appendix B: Example Prometheus Queries

```promql
# Top 5 most watched items
topk(5, jellyfin_item_play_count)

# Transcode vs direct play ratio
sum(rate(jellyfin_playback_total{type="transcode"}[1h])) /
sum(rate(jellyfin_playback_total[1h]))

# Average bandwidth per user
sum(jellyfin_bandwidth_bytes_per_second) /
count(count by(user) (jellyfin_sessions_active))

# Library growth rate
rate(jellyfin_library_items_total[7d])

# Peak concurrent users
max_over_time(jellyfin_active_users[7d])
```

## Appendix C: References

- [Jellyfin API Documentation](https://api.jellyfin.org)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [Grafana Dashboard Design](https://grafana.com/docs/grafana/latest/dashboards/)
- [VictoriaMetrics Documentation](https://docs.victoriametrics.com/)
- [NixOS Services](https://nixos.org/manual/nixos/stable/#sec-writing-modules)

---

_Document Version: 1.0_
_Last Updated: 2025-01-21_
_Author: System Architecture Team_
