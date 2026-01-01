{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.vmalert;
in
{
  options.systemFoundry.monitoringStack.vmalert = {
    enable = mkEnableOption "vmalert for alerting rules evaluation";

    port = mkOption {
      type = types.port;
      default = 8880;
      description = "Port for vmalert web interface";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    domain = mkOption {
      type = types.str;
      default = "vmalert.${parentCfg.domain}";
      description = "Domain name for vmalert UI (defaults to vmalert.{parent domain})";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for vmalert domain";
    };

    datasourceUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8428";
      description = "VictoriaMetrics datasource URL";
    };

    notifierUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:9093";
      description = "Alertmanager notifier URL";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Write rules to a single properly formatted YAML file
    environment.etc."vmalert/rules.yml".text = ''
      groups:
        # Host availability monitoring
        - name: host_availability
          interval: 30s
          rules:
            - alert: InstanceDown
              expr: up == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Instance {{ $labels.instance }} is down"
                description: "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes."

        # Systemd service health
        - name: systemd_health
          interval: 30s
          rules:
            # Exclude drkonqi-coredump-processor@* services - these are KDE's transient
            # crash dump processors that often timeout during session disruptions (logout,
            # display server restart). The underlying application crash is the real issue,
            # not the processor failure. These create noise without actionable information.
            - alert: SystemdServiceFailed
              expr: node_systemd_unit_state{state="failed",name!~"drkonqi-.*"} == 1
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Systemd service {{ $labels.name }} failed on {{ $labels.instance }}"
                description: "Service {{ $labels.name }} is in failed state on {{ $labels.instance }}"

            - alert: SystemdServiceCrashlooping
              expr: increase(node_systemd_service_restart_total[15m]) > 5
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Systemd service {{ $labels.name }} is crashlooping on {{ $labels.instance }}"
                description: "Service {{ $labels.name }} has restarted more than 5 times in the last 15 minutes on {{ $labels.instance }}"

            - alert: JellyfinDown
              expr: node_systemd_unit_state{host="wolf",name="jellyfin.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: jellyfin
              annotations:
                summary: "Jellyfin service is down on wolf"
                description: "Jellyfin has been unavailable for 5 minutes"

        # Disk space monitoring
        - name: disk_space
          interval: 60s
          rules:
            # Special rule for tiger /mnt/media - allow lower free space (media library fills up)
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{host="tiger",mountpoint="/mnt/media"} / node_filesystem_size_bytes{host="tiger",mountpoint="/mnt/media"} < 0.05) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 5% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{host="tiger",mountpoint="/mnt/media"} / node_filesystem_size_bytes{host="tiger",mountpoint="/mnt/media"} < 0.03) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 3% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            # Default disk space alerts for all other filesystems
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media"} < 0.15) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 15% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media"} < 0.10) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 10% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskWillFillSoon
              expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"}[6h], 24*3600) < 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Disk will fill within 24 hours on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Based on the last 6 hours, filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} will fill up within 24 hours"

        # Resource usage monitoring
        - name: resource_usage
          interval: 30s
          rules:
            - alert: HighCPULoad
              expr: node_load1 / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"}) > 2
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "High CPU load on {{ $labels.instance }}"
                description: "CPU load per core has been above 2 for 15 minutes on {{ $labels.instance }}. Current load per core: {{ $value | printf \"%.2f\" }}"

            - alert: HighCPULoadCritical
              expr: node_load1 / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"}) > 4
              for: 15m
              labels:
                severity: critical
              annotations:
                summary: "Critical CPU load on {{ $labels.instance }}"
                description: "CPU load per core has been above 4 for 15 minutes on {{ $labels.instance }}. Current load per core: {{ $value | printf \"%.2f\" }}"

            - alert: HighMemoryUsage
              expr: (1 - ((node_memory_MemAvailable_bytes + (node_zfs_arc_size or 0)) / node_memory_MemTotal_bytes)) > 0.85
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "High memory usage on {{ $labels.instance }}"
                description: "Memory usage is above 85% on {{ $labels.instance }} (excluding reclaimable ZFS ARC). Current: {{ $value | humanizePercentage }}"

            - alert: HighMemoryUsageCritical
              expr: (1 - ((node_memory_MemAvailable_bytes + (node_zfs_arc_size or 0)) / node_memory_MemTotal_bytes)) > 0.95
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical memory usage on {{ $labels.instance }}"
                description: "Memory usage is above 95% on {{ $labels.instance }} (excluding reclaimable ZFS ARC). Current: {{ $value | humanizePercentage }}"

            - alert: HostMemoryPressure
              expr: rate(node_vmstat_pgmajfault[5m]) > 1000
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Host under memory pressure on {{ $labels.instance }}"
                description: "The host is experiencing high page fault rate ({{ $value | printf \"%.2f\" }} faults/sec), indicating memory pressure on {{ $labels.instance }}"

        # YouTube Downloader service health
        - name: youtube_downloader
          interval: 60s
          rules:
            - alert: YTDownloaderStale
              expr: (time() - yt_last_run_timestamp) > 172800
              for: 1m
              labels:
                severity: critical
                service: youtube-downloader
              annotations:
                summary: "YouTube downloader has not run in {{ $value | humanizeDuration }}"
                description: "Last successful run was {{ $value | humanizeDuration }} ago. Expected daily runs."

            - alert: YTDownloaderHighFailureRate
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

        # Cogsworth kiosk monitoring
        - name: cogsworth_monitoring
          interval: 30s
          rules:
            - alert: CogsworthServiceDown
              expr: node_systemd_unit_state{host="cogsworth",name="cogsworth.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Cogsworth application is down"
                description: "Cogsworth service has been unavailable for 5 minutes on the kiosk"

            - alert: CogsworthWatchdogTriggered
              expr: increase(node_systemd_service_restart_total{host="cogsworth",name="cogsworth.service"}[15m]) > 2
              for: 1m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth watchdog triggered {{ $value }} restarts"
                description: "Cogsworth service has been restarted {{ $value }} times in the last 15 minutes. The three-tier watchdog may be recovering from failures."

            - alert: CogsworthHighMemory
              expr: (1 - (node_memory_MemAvailable_bytes{host="cogsworth"} / node_memory_MemTotal_bytes{host="cogsworth"})) > 0.80
              for: 10m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth memory usage is {{ $value | humanizePercentage }}"
                description: "Raspberry Pi memory usage is above 80% on cogsworth. Pi has limited RAM (Java heap: 64-256MB)."

            - alert: CogsworthHighMemoryCritical
              expr: (1 - (node_memory_MemAvailable_bytes{host="cogsworth"} / node_memory_MemTotal_bytes{host="cogsworth"})) > 0.90
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Cogsworth memory usage is {{ $value | humanizePercentage }}"
                description: "Raspberry Pi memory usage is critically high (>90%) on cogsworth. Risk of OOM killer."

            - alert: CogsworthKioskDown
              expr: node_systemd_unit_state{host="cogsworth",name="cage-tty1.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Cogsworth kiosk display is down"
                description: "Cage compositor (kiosk display) has been down for 5 minutes on cogsworth"

            - alert: CogsworthHighCPUTemp
              expr: node_hwmon_temp_celsius{host="cogsworth"} > 70
              for: 10m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth CPU temperature is {{ $value }}°C"
                description: "Raspberry Pi CPU temperature exceeds 70°C. Check cooling/ventilation."

            # Cogsworth application metrics - Critical alerts
            - alert: CalendarSyncCriticallyStale
              expr: time() - cogsworth_sync_last_success_timestamp_seconds > 3600
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Calendar sync critically stale for {{ $labels.member_id }}"
                description: "Calendar for {{ $labels.member_id }} ({{ $labels.calendar_type }}) has not synced successfully in over 1 hour."

            - alert: HighSyncErrorRate
              expr: sum(rate(cogsworth_sync_total{status="error"}[15m])) / sum(rate(cogsworth_sync_total[15m])) > 0.2
              for: 10m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "High sync error rate: {{ $value | humanizePercentage }}"
                description: "More than 20% of calendar sync operations are failing."

            - alert: HTTPTimeoutSpike
              expr: sum(rate(cogsworth_http_client_errors_total{error_type="timeout"}[5m])) > 0.1
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "HTTP timeout spike detected"
                description: "Experiencing {{ $value }} timeouts/sec when fetching calendars from iCloud/webcal."

            - alert: CogsworthMetricsDown
              expr: up{job="cogsworth"} == 0
              for: 2m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Cogsworth metrics endpoint is down"
                description: "Cannot scrape metrics from Cogsworth application endpoint at :8080/metrics."

            # Cogsworth application metrics - Warning alerts
            - alert: CalendarSyncStale
              expr: time() - cogsworth_sync_last_success_timestamp_seconds > 1800
              for: 5m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Calendar sync stale for {{ $labels.member_id }}"
                description: "Calendar for {{ $labels.member_id }} ({{ $labels.calendar_type }}) has not synced in over 30 minutes."

            - alert: SlowSyncOperations
              expr: histogram_quantile(0.95, sum by (le) (rate(cogsworth_sync_duration_seconds_bucket[5m]))) > 5
              for: 15m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Sync operations are slow"
                description: "P95 sync duration is {{ $value }}s (threshold: 5s). Calendar fetches may be experiencing latency."

            - alert: HighHTTPLatency
              expr: histogram_quantile(0.95, sum by (le) (rate(cogsworth_http_client_request_duration_seconds_bucket[5m]))) > 10
              for: 10m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "High HTTP latency to calendar services"
                description: "P95 HTTP latency is {{ $value }}s (threshold: 10s). Check iCloud/webcal service status."

            - alert: CacheEventsDropped
              expr: (cogsworth_cache_events_total - cogsworth_cache_events_total offset 1h) / (cogsworth_cache_events_total offset 1h) < -0.5
              for: 5m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cached events dropped for {{ $labels.member_id }}"
                description: "Cache for {{ $labels.member_id }} has dropped by more than 50%. This may indicate sync issues or calendar data loss."
    '';

    systemd.services.vmalert = {
      description = "vmalert - evaluation of alerting rules";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = "vmalert";
        Group = "vmalert";
        ExecStart = ''
          ${pkgs.victoriametrics}/bin/vmalert \
            -datasource.url=${cfg.datasourceUrl} \
            -notifier.url=${cfg.notifierUrl} \
            -httpListenAddr=${cfg.listenAddress}:${toString cfg.port} \
            -external.url=https://${cfg.domain} \
            -rule=/etc/vmalert/rules.yml \
            -evaluationInterval=15s
        '';
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # Auto-reload vmalert when rules file changes
    systemd.paths.vmalert-rules-watcher = {
      description = "Watch vmalert rules file for changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = "/etc/vmalert/rules.yml";
        Unit = "vmalert-reload.service";
      };
    };

    systemd.services.vmalert-reload = {
      description = "Reload vmalert after rules change";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl reload-or-restart vmalert.service";
      };
    };

    users.users.vmalert = {
      isSystemUser = true;
      group = "vmalert";
      description = "vmalert service user";
    };

    users.groups.vmalert = { };

    # Expose vmalert UI via nginx reverse proxy with basic auth
    systemFoundry.nginxReverseProxy.sites."${cfg.domain}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:${toString cfg.port}";
      provisionCert = cfg.provisionCert;
      route53HostedZoneId = "Z0365859SHHFAPNR0QXN"; # ondy.org zone
      extraConfig = ''
        auth_basic "vmalert Admin";
        auth_basic_user_file ${config.sops.secrets.vmalert_htpasswd.path};
      '';
    };

    # Create htpasswd secret for basic auth
    sops.secrets.vmalert_htpasswd = {
      owner = "nginx";
      group = "nginx";
      mode = "0440";
    };
  };
}
