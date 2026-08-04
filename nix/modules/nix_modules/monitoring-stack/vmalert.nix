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
            - alert: SystemdServiceFailed
              expr: node_systemd_unit_state{state="failed"} == 1
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
              expr: node_systemd_unit_state{host="tiger",name="jellyfin.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: jellyfin
              annotations:
                summary: "Jellyfin service is down on tiger"
                description: "Jellyfin has been unavailable for 5 minutes"

        # Media Services (tiger)
        - name: media_services_tiger
          interval: 30s
          rules:
            - alert: SonarrDown
              expr: node_systemd_unit_state{host="tiger",name="sonarr.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: sonarr
              annotations:
                summary: "Sonarr service is down on tiger"
                description: "Sonarr has been unavailable for 5 minutes"

            - alert: RadarrDown
              expr: node_systemd_unit_state{host="tiger",name="radarr.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: radarr
              annotations:
                summary: "Radarr service is down on tiger"
                description: "Radarr has been unavailable for 5 minutes"

            - alert: LidarrDown
              expr: node_systemd_unit_state{host="tiger",name="lidarr.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: lidarr
              annotations:
                summary: "Lidarr service is down on tiger"
                description: "Lidarr has been unavailable for 5 minutes"

            - alert: ProwlarrDown
              expr: node_systemd_unit_state{host="tiger",name="prowlarr.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: prowlarr
              annotations:
                summary: "Prowlarr service is down on tiger"
                description: "Prowlarr has been unavailable for 5 minutes"

            - alert: SABnzbdDown
              expr: node_systemd_unit_state{host="tiger",name="sabnzbd.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: sabnzbd
              annotations:
                summary: "SABnzbd service is down on tiger"
                description: "SABnzbd has been unavailable for 5 minutes"

            - alert: JellyseerrDown
              expr: node_systemd_unit_state{host="tiger",name="jellyseerr.service",state="active"} != 1
              for: 5m
              labels:
                severity: critical
                service: jellyseerr
              annotations:
                summary: "Jellyseerr service is down on tiger"
                description: "Jellyseerr has been unavailable for 5 minutes"

        # Arr Queue Health (exportarr metrics)
        - name: arr_queue_health
          interval: 60s
          rules:
            - alert: SonarrQueueHigh
              expr: sonarr_queue_total > 50
              for: 4h
              labels:
                severity: warning
                service: sonarr
              annotations:
                summary: "Sonarr queue depth is high: {{ $value }} items"
                description: "Sonarr has more than 50 items in queue for 4+ hours"

            - alert: SonarrQueueStalled
              expr: increase(sonarr_queue_total[6h]) == 0 AND sonarr_queue_total > 0
              for: 6h
              labels:
                severity: warning
                service: sonarr
              annotations:
                summary: "Sonarr queue appears stalled"
                description: "Sonarr queue has items stuck - no movement in 6 hours"

            - alert: RadarrQueueHigh
              expr: radarr_queue_total > 50
              for: 4h
              labels:
                severity: warning
                service: radarr
              annotations:
                summary: "Radarr queue depth is high: {{ $value }} items"
                description: "Radarr has more than 50 items in queue for 4+ hours"

            - alert: RadarrQueueStalled
              expr: increase(radarr_queue_total[6h]) == 0 AND radarr_queue_total > 0
              for: 6h
              labels:
                severity: warning
                service: radarr
              annotations:
                summary: "Radarr queue appears stalled"
                description: "Radarr queue has items stuck - no movement in 6 hours"

            - alert: SABnzbdQueueHigh
              expr: sabnzbd_queue_length > 20
              for: 4h
              labels:
                severity: warning
                service: sabnzbd
              annotations:
                summary: "SABnzbd queue depth is high: {{ $value }} items"
                description: "SABnzbd has more than 20 items in queue for 4+ hours"

            - alert: SABnzbdDiskSpaceLow
              expr: (sabnzbd_disk_total_bytes{folder="download"} - sabnzbd_disk_used_bytes{folder="download"}) < 50 * 1024 * 1024 * 1024
              for: 1h
              labels:
                severity: warning
                service: sabnzbd
              annotations:
                summary: "SABnzbd download free space low on {{ $labels.host }}: {{ $value | humanize1024 }}B free"
                description: "SABnzbd reports less than 50GB free on its download directory for 1+ hour"

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

            # Default disk space alerts for all other filesystems.
            # macOS mounts removable media, .dmg installers and network shares
            # under /Volumes; none of them are this host's storage to manage, and
            # a writable USB stick evades the readonly guard below.
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} < 0.15) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 15% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} < 0.10) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 10% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskWillFillSoon
              expr: (predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!~"/Volumes/.*"}[6h], 24*3600) < 0) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Disk will fill within 24 hours on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Based on the last 6 hours, filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} will fill up within 24 hours"

        # Drive health monitoring: SMART and mdraid
        - name: drive_health
          interval: 60s
          rules:
            - alert: SmartDriveHealthFailed
              expr: |
                smartctl_device_smart_healthy == 0
                unless on(host, device, serial) (
                  smartctl_nvme_critical_warning == 4
                  and smartctl_nvme_available_spare > smartctl_nvme_available_spare_threshold
                )
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "SMART health failure on {{ $labels.host }}:{{ $labels.device }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} is reporting a SMART health failure. Run: smartctl -a /dev/{{ $labels.device }}"

            - alert: SmartDriveAvailableSpareLow
              expr: smartctl_nvme_available_spare <= smartctl_nvme_available_spare_threshold
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "NVMe spare exhausted on {{ $labels.host }}:{{ $labels.device }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} has Available Spare at or below the threshold. Replace ASAP."

            - alert: SmartDriveEnduranceExceeded
              expr: smartctl_nvme_percentage_used >= 100
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "NVMe endurance exceeded on {{ $labels.host }}:{{ $labels.device }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} has Percentage Used >= 100% (warranty endurance exhausted). Drive is still healthy while Available Spare > threshold."

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


        # ZFS pool health and scrub freshness.
        #
        # Neither existed on any host before this group. SystemdServiceFailed
        # looks like it covers the scrub and does not: a oneshot that never
        # runs never enters `failed`, so a disabled timer, a misfire, or a
        # host that was down at the trigger are all invisible. The only
        # reliable signal is the absence of a recent success.
        #
        # Metric names matter here. zfs_zpool_* was renamed zfs_pool_* and
        # the poolname label became pool (DASHBOARD_CONVENTIONS.md:413), so a
        # rule written from memory matches nothing, forever, silently.
        - name: zfs_storage
          interval: 60s
          rules:
            - alert: ZpoolNotOnline
              expr: zfs_pool_health != 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Pool {{ $labels.pool }} on {{ $labels.host }} is not ONLINE"
                description: "zfs_pool_health is {{ $value }} for {{ $labels.pool }} on {{ $labels.host }} (0 ONLINE, 1 DEGRADED, 2 FAULTED, 3 OFFLINE, 4 UNAVAIL, 5 REMOVED, 6 SUSPENDED). Run `zpool status -v` there."

            # The `> 0` is load-bearing: a never-scrubbed pool reports the
            # sentinel 0, and `time() - 0` reads as 1970. ZpoolNeverScrubbed
            # is what covers that case.
            - alert: ZpoolScrubStale
              expr: (time() - (zfs_pool_scrub_end_timestamp_seconds > 0) > 45 * 86400) and on(pool, host) zfs_pool_scrub_in_progress == 0
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Pool {{ $labels.pool }} on {{ $labels.host }} has not completed a scrub in over 45 days"
                description: "No scrub of {{ $labels.pool }} on {{ $labels.host }} has finished in 45 days and none is running. Silent corruption is only found by scrubbing, and a resilver is the worst time to discover it. Check services.zfs.autoScrub on that host."

            # Age lives in the expression, not in `for:`: vmalert runs with
            # no -remoteRead.url and restarts on every rules edit, so a long
            # `for:` resets before it ever elapses.
            - alert: ZpoolNeverScrubbed
              expr: (zfs_pool_scrub_end_timestamp_seconds == 0) and on(pool, host) (time() - zfs_pool_creation_timestamp_seconds > 7 * 86400) and on(pool, host) zfs_pool_scrub_in_progress == 0
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Pool {{ $labels.pool }} on {{ $labels.host }} has never been scrubbed"
                description: "{{ $labels.pool }} on {{ $labels.host }} was created over 7 days ago and has never completed a scrub. A pool that has never been read end to end has never proven it can be. Check services.zfs.autoScrub, or run `zpool scrub {{ $labels.pool }}` there once."

            # The two rules above both depend on metrics that come from a
            # textfile collector, and a collector that stops writing takes
            # its own alerts with it. This is the absence check on the
            # absence check: any host reporting pool health but no scrub
            # timestamp has lost ZpoolScrubStale without anyone noticing.
            - alert: ZpoolScrubMetricMissing
              expr: count by (host) (zfs_pool_health) unless count by (host) (zfs_pool_scrub_end_timestamp_seconds)
              for: 2h
              labels:
                severity: warning
              annotations:
                summary: "Scrub age metric missing on {{ $labels.host }}"
                description: "{{ $labels.host }} reports zfs_pool_health but no zfs_pool_scrub_end_timestamp_seconds, so ZpoolScrubStale cannot fire there. Check the zfs-scrub-exporter unit and its timer."

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
                description: "Raspberry Pi memory usage is above 80% on cogsworth."

            - alert: CogsworthHighMemoryCritical
              expr: (1 - (node_memory_MemAvailable_bytes{host="cogsworth"} / node_memory_MemTotal_bytes{host="cogsworth"})) > 0.90
              for: 5m
              labels:
                severity: critical
                service: cogsworth
              annotations:
                summary: "Cogsworth memory usage is {{ $value | humanizePercentage }}"
                description: "Raspberry Pi memory usage is critically high (>90%) on cogsworth. Risk of OOM killer."

            - alert: CogsworthHighCPUTemp
              expr: node_hwmon_temp_celsius{host="cogsworth"} > 70
              for: 10m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth CPU temperature is {{ $value }}°C"
                description: "Raspberry Pi CPU temperature exceeds 70°C. Check cooling/ventilation."
    '';

    systemd.services.vmalert = {
      description = "vmalert - evaluation of alerting rules";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      restartTriggers = [
        config.environment.etc."vmalert/rules.yml".text
      ];

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

    users.users.vmalert = {
      isSystemUser = true;
      group = "vmalert";
      description = "vmalert service user";
    };

    users.groups.vmalert = { };

    # Caddy reverse proxy (basic auth on all paths, protects the UI)
    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          basicAuth = parentCfg.monitoringBasicAuth;
          basicAuthPaths = [ ]; # empty = protect all paths
        };
  };
}
