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

            # up{host="X"} is pushed by X's own vmagent, so an off or
            # unreachable host drops the series rather than setting it to 0,
            # leaving InstanceDown matching nothing. trex is excluded on
            # purpose: it is dark about two thirds of the time. One rule per
            # host with an equality matcher, because a regex matcher fires
            # only once every host it matches is gone and carries no labels.
            - alert: HostAbsent
              expr: absent(up{host="cogsworth"})
              for: 10m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.host }} has stopped reporting"
                description: "No up series exists for {{ $labels.host }} at all, so the host is powered off, off the network, or its vmagent is dead. Check power and link first, then `systemctl status vmagent` on the host. A deploy reboot longer than 10 minutes also lands here."

            - alert: HostAbsent
              expr: absent(up{host="pika"})
              for: 10m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.host }} has stopped reporting"
                description: "No up series exists for {{ $labels.host }} at all, so the host is powered off, off the network, or its vmagent is dead. Check power and link first, then `systemctl status vmagent` on the host. A deploy reboot longer than 10 minutes also lands here."

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

            # Keyed on download_state, not on increase(gauge[6h]) == 0:
            # MetricsQL reads a gauge decrease as a counter reset, so one item
            # leaving the state restarts the `for:` for every other item in it.
            - alert: SonarrImportBlocked
              expr: sum by (host) (sonarr_queue_total{download_state=~"importBlocked|failedPending"}) > 0
              for: 24h
              labels:
                severity: warning
                service: sonarr
              annotations:
                summary: "Sonarr has {{ $value }} queue item(s) blocked from importing"
                description: "Sonarr retries these every 60s and is still blocked, so they need a decision, not time. Open https://sonarr.tiger.infra.ondy.org/activity/queue and either manual-import or remove them. arr-queue-janitor removes and blocklists anything still here at 48h."

            - alert: RadarrQueueHigh
              expr: radarr_queue_total > 50
              for: 4h
              labels:
                severity: warning
                service: radarr
              annotations:
                summary: "Radarr queue depth is high: {{ $value }} items"
                description: "Radarr has more than 50 items in queue for 4+ hours"

            - alert: RadarrImportBlocked
              expr: sum by (host) (radarr_queue_total{download_state=~"importBlocked|failedPending"}) > 0
              for: 24h
              labels:
                severity: warning
                service: radarr
              annotations:
                summary: "Radarr has {{ $value }} queue item(s) blocked from importing"
                description: "Radarr retries these every 60s and is still blocked, so they need a decision, not time. Open https://radarr.tiger.infra.ondy.org/activity/queue and either manual-import or remove them. arr-queue-janitor removes and blocklists anything still here at 48h."

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

            # predict_linear reads any step change as a trend, so a one-off
            # write (a batch of model downloads) forecasts a full disk. The
            # floor keeps that arithmetic from mattering while headroom is
            # ample, and the 24h window dilutes single bursts.
            - alert: DiskWillFillSoon
              expr: |
                (
                  predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"}[24h], 24*3600) < 0
                  and
                  node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"}
                    / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} < 0.20
                )
                and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Disk will fill within 24 hours on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Based on the last 24 hours, filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} will fill up within 24 hours"

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

        # Tier 2 of docs/backup-strategy.md: tiger snapshots, pika pulls.
        #
        # Freshness is measured the same way on both ends, so the pair says
        # which end broke. Stale on pika alone is replication; stale on both
        # is sanoid on tiger. Nothing here watches a syncoid exit code, for
        # the reason the doc gives under "Why none of it watches an exit
        # code", which the ordering below encodes: a leg that never runs
        # never fails.
        - name: backup_replication
          interval: 60s
          rules:
            # Ordered by what fails first. Empty and missing come before
            # stale because both delete the timestamp series outright, and
            # a staleness rule with nothing to subtract from matches
            # nothing at all rather than firing.
            - alert: BackupReplicaDatasetMissing
              expr: absent(zfs_dataset_snapshot_count{host="pika",dataset="tank/photos"}) or absent(zfs_dataset_snapshot_count{host="pika",dataset="tank/backups"})
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Backup dataset {{ $labels.dataset }} is gone from pika"
                description: "{{ $labels.dataset }} reports no snapshot metrics at all on pika. Either the dataset was destroyed, or zfs-snapshot-exporter is not writing. Both leave every other rule in this group matching nothing. Check `zfs list -r tank` and `systemctl status zfs-snapshot-exporter` on pika."

            - alert: BackupReplicaEmpty
              expr: zfs_dataset_snapshot_count{host="pika",dataset=~"tank/(photos|backups)"} == 0
              for: 2h
              labels:
                severity: critical
              annotations:
                summary: "Backup dataset {{ $labels.dataset }} on pika holds no snapshots"
                description: "{{ $labels.dataset }} exists on pika but holds zero snapshots, so the second copy of this data does not exist. sanoid on pika prunes and never creates, so it cannot refill this on its own. Check syncoid and pika's retention against tiger's."

            - alert: BackupReplicaStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="pika",dataset=~"tank/(photos|backups)"} > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Backup of {{ $labels.dataset }} on pika is over 36 hours old"
                description: "The newest snapshot in {{ $labels.dataset }} on pika is more than 36 hours old, against a daily syncoid timer. If the matching storage dataset on tiger is fresh, replication is the broken end: check `systemctl status syncoid-storage-*` on pika."

            - alert: BackupReplicaCriticallyStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="pika",dataset=~"tank/(photos|backups)"} > 72 * 3600
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Backup of {{ $labels.dataset }} on pika is over 72 hours old"
                description: "The newest snapshot in {{ $labels.dataset }} on pika is more than 72 hours old. Three daily runs have now failed to land anything. Treat the second copy as not current."

            # tiger's own snapshots, because pika can only be as fresh as
            # what it is pulling from.
            - alert: BackupSourceSnapshotsStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="tiger",dataset=~"storage/(photos|backups)"} > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Snapshots of {{ $labels.dataset }} on tiger are over 36 hours old"
                description: "sanoid on tiger has not made a snapshot of {{ $labels.dataset }} in over 36 hours, against an hourly-and-daily policy. pika replicates snapshots and creates none of its own, so this staleness reaches the backup too. Check `systemctl status sanoid` on tiger."

        # The offsite tier, tier 3 of docs/backup-strategy.md. Same ordering
        # as backup_replication above: absence first, because a push that
        # never runs publishes nothing to be stale about.
        #
        # These rules go quiet during an initial seed, which legitimately runs
        # for days before recording a first success. Silence, do not retune.
        - name: offsite_archive
          interval: 60s
          rules:
            - alert: S3ArchivePushNeverSucceeded
              expr: absent(s3_archive_push_last_success_timestamp_seconds{host="pika",prefix="photos"}) or absent(s3_archive_push_last_success_timestamp_seconds{host="pika",prefix="backups"})
              for: 24h
              labels:
                severity: warning
              annotations:
                summary: "Offsite push for one prefix has never recorded a success"
                description: "No s3_archive_push_last_success_timestamp_seconds series exists for one of the two prefixes, so that half of the offsite copy may not exist at all. Expected while a prefix is still seeding. Otherwise check `systemctl status s3-archive-push-*` on pika: the unit refuses to run against an unmounted dataset, which is the usual cause."

            - alert: S3ArchivePushStale
              expr: time() - s3_archive_push_last_success_timestamp_seconds{host="pika"} > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Offsite push of {{ $labels.prefix }}/ is over 36 hours old"
                description: "The last clean sync of {{ $labels.prefix }}/ to the archive bucket is more than 36 hours old, against a daily timer. pika still holds the second copy, so this is not yet data loss, only loss of the offsite one. Check `journalctl -u s3-archive-push-{{ $labels.prefix }}` on pika."

            - alert: S3ArchivePushCriticallyStale
              expr: time() - s3_archive_push_last_success_timestamp_seconds{host="pika"} > 96 * 3600
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Offsite push of {{ $labels.prefix }}/ is over 96 hours old"
                description: "Four daily runs have failed to complete a sync of {{ $labels.prefix }}/. Treat the offsite copy as not current: anything imported since then exists only in the house."

            - alert: S3ArchiveObjectsMissing
              expr: s3_reconcile_missing_objects{host="pika"} > 0
              for: 6h
              labels:
                severity: critical
              annotations:
                summary: "{{ $value }} files under {{ $labels.prefix }}/ are absent from the archive bucket"
                description: "Reconciliation found source files with no object in the bucket, which means the sync believes it is current while the offsite copy is not. This is the failure the whole tier exists to prevent. Run `systemctl start s3-archive-reconcile-{{ $labels.prefix }}` on pika and read its journal to list them; that unit reports without deleting."

            - alert: S3ArchivePruneBlocked
              expr: s3_reconcile_prune_blocked{host="pika"} > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Offsite prune of {{ $labels.prefix }}/ refused to run"
                description: "The orphan count exceeded the safety threshold, so nothing was deleted. Either a genuinely large cull happened, or the source listing is wrong. Confirm the dataset is mounted and holds what you expect before overriding by hand."

            - alert: S3ReconcileStale
              expr: time() - s3_reconcile_last_run_timestamp_seconds{host="pika"} > 14 * 24 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Offsite reconciliation of {{ $labels.prefix }}/ has not run in 14 days"
                description: "Nothing has compared the bucket against the source in two weeks, against a weekly timer. Both S3ArchiveObjectsMissing and the orphan count are computed here, so this rule going quiet takes those with it."

            # S3ReconcileStale subtracts from a series that only exists after a
            # first successful run, so it cannot fire before one.
            - alert: S3ReconcileNeverRan
              expr: absent(s3_reconcile_last_run_timestamp_seconds{host="pika",prefix="photos"}) or absent(s3_reconcile_last_run_timestamp_seconds{host="pika",prefix="backups"})
              for: 8d
              labels:
                severity: warning
              annotations:
                summary: "Offsite reconciliation for one prefix has never recorded a run"
                description: "No s3_reconcile_last_run_timestamp_seconds series exists for one of the two prefixes. The timers are weekly, photos on Sunday and backups on Monday, so 8 days is one full cycle plus slack. Check `systemctl status s3-archive-prune-photos s3-archive-prune-backups` on pika."

        # Windows machines mirroring into storage/backups over SMB
        # (docs/windows-backup.md). Once the files land, tiger's snapshots,
        # pika and the S3 tier already cover them and the groups above already
        # watch that. The only leg with no coverage is the client, and it is
        # the one leg nothing in this fleet controls: the push is a Windows
        # scheduled task, so there is no unit to fail here when it stops.
        - name: windows_backup
          interval: 60s
          rules:
            # `> 0` is load-bearing for the same reason it is in ZpoolScrubStale
            # above: a missing heartbeat reports the sentinel 0 and `time() - 0`
            # reads as 1970. WindowsBackupHeartbeatMissing covers that case.
            - alert: WindowsBackupStale
              expr: time() - (windows_backup_last_success_timestamp_seconds{host="tiger"} > 0) > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Windows backup of {{ $labels.machine }} is over 36 hours old"
                description: "{{ $labels.machine }} has not completed a mirror in over 36 hours, against a daily scheduled task. The PC being off explains it; so does a task that has silently stopped, a changed SMB password, or a full pool. Check the Task Scheduler history and %LOCALAPPDATA%\\tiger-backup.log on the PC."

            - alert: WindowsBackupCriticallyStale
              expr: time() - (windows_backup_last_success_timestamp_seconds{host="tiger"} > 0) > 72 * 3600
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Windows backup of {{ $labels.machine }} is over 72 hours old"
                description: "Three daily runs of the {{ $labels.machine }} mirror have failed to land anything. Whatever that PC has created since then exists only on that PC."

            # Age in the expression rather than in `for:`, for the reason
            # ZpoolNeverScrubbed gives above: vmalert restarts on every rules
            # edit, so a long `for:` resets before it elapses. The directory
            # mtime is the grace anchor, so provisioning a machine on tiger
            # does not alert before anyone could have set the PC up.
            - alert: WindowsBackupNeverSucceeded
              expr: (windows_backup_last_success_timestamp_seconds{host="tiger"} == 0) and on(machine) (time() - windows_backup_target_mtime_seconds{host="tiger"} > 7 * 86400)
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Windows backup of {{ $labels.machine }} has never run"
                description: "/mnt/backups/{{ $labels.machine }} was created over 7 days ago and still holds no _heartbeat, so that machine has never completed a mirror. Either the Windows side was never set up, or every run so far has failed before the last step. docs/windows-backup.md has the client setup; the log is %LOCALAPPDATA%\\tiger-backup.log on the PC."

            - alert: WindowsBackupExporterMissing
              expr: absent(windows_backup_last_success_timestamp_seconds{host="tiger"})
              for: 2h
              labels:
                severity: warning
              annotations:
                summary: "Windows backup freshness metric missing on tiger"
                description: "No windows_backup_last_success_timestamp_seconds series exists at all, so every rule in this group matches nothing. This is the absence check on the absence check. Run `systemctl status win-backup-exporter` and check its timer on tiger."

        # SMART health, scrub age and backup freshness all arrive this way.
        # node_exporter drops a file it cannot parse and keeps serving the
        # rest, so a broken producer costs its alerts in silence:
        # test-youtube-metrics.prom did that on tiger for nine months.
        - name: textfile_collector
          interval: 60s
          rules:
            - alert: NodeTextfileCollectorFailing
              expr: node_textfile_scrape_error != 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "node_exporter textfile collector failing on {{ $labels.host }}"
                description: "At least one .prom file in /var/lib/prometheus-node-exporter-text-files on {{ $labels.host }} is unreadable or malformed, and every metric in it is absent. The file name is in the error: journalctl -u prometheus-node-exporter | grep textfile"

        # SystemdServiceFailed already catches a run that exits non-zero. These
        # two cover what it cannot see: a run that succeeds while fetching
        # nothing, and a sweeper that dies and freezes the gauge the first rule
        # reads. Ordering matters, so the sweeper rule fires first at 48h and
        # answers "is the metric even live" before the stall rule speaks.
        - name: ytdl_sub
          interval: 60s
          rules:
            - alert: YtdlSubHousekeepingStale
              expr: time() - ytdl_sub_housekeeping_last_run_timestamp_seconds > 172800
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "ytdl-sub housekeeping has not run in 48h on {{ $labels.host }}"
                description: "The daily sweep writes every ytdl_sub_* metric, so while it is down the freshness gauge is frozen and YtdlSubStalled below is reading a stale number rather than a real stall. Fix this one first: systemctl status ytdl-sub-housekeeping on {{ $labels.host }}."

            - alert: YtdlSubStalled
              expr: time() - ytdl_sub_last_download_timestamp_seconds > 604800
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "No new YouTube video downloaded in 7 days on {{ $labels.host }}"
                description: >-
                  Check format availability before anything else, because this
                  is usually not throttling. Run `yt-dlp -F <any channel url>`
                  on {{ $labels.host }}. If the only media format offered is 18
                  (640x360), a player client has gone SABR-only and itag 18 is
                  the one format exempt from the PO token check, which is
                  exactly what stalled this service through spring 2026. The
                  fix is a client change, not more sleeping: try
                  `--extractor-args youtube:player_client=mweb` plus a PO token
                  provider (bgutil, recoverable from git 0dc712f8). Genuine rate
                  limiting looks different and shows HTTP 429. A quiet week
                  across all channels is also possible, so confirm against
                  ytdl_sub_videos_total before digging.

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

            # sync_state.last_sync_at is stamped on every outcome including
            # the error branch, so staleness of that timestamp proves
            # nothing and the status is the only usable signal. Calendars
            # whose URL was blanked are filtered out by the app, not here.
            - alert: CogsworthCalendarSyncFailing
              expr: min_over_time(cogsworth_calendar_sync_ok[6h]) == 0
              for: 15m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Calendar {{ $labels.calendar_id }} has not synced for 6 hours"
                description: "Every webcal fetch for {{ $labels.calendar_id }} in the last 6 hours returned an error, so the kiosk is serving cached events that go on quietly aging while the display looks normal. A dead iCloud share URL is the usual cause and returns 404. Run `curl -s localhost:8080/api/admin/sync-states` on cogsworth for the error text, then re-share the calendar and paste the new URL into the admin UI."

            # Every periodic task records success at one choke point in
            # cogsworth.scheduler/safe-run, which already swallows throws to
            # keep the ticker alive. A task that hangs stops the next tick
            # with no exception and no log, and this is the only thing that
            # sees it. The 24h cleanups are deliberately unalerted: their
            # failure surfaces as disk growth, which DiskWillFillSoon covers.
            - alert: CogsworthJobStalled
              expr: |
                time() - cogsworth_job_last_success_timestamp_seconds{task=~"display-loop|light-loop|presence-broadcast|scheduled-reboot|sms-poll|weather-poll|webcal-sync"} > 3600
                or
                time() - cogsworth_job_last_success_timestamp_seconds{task=~"immich-sync|gphotos-sync"} > 86400
              for: 15m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth job {{ $labels.task }} has not succeeded in {{ $value | humanizeDuration }}"
                description: "Background task {{ $labels.task }} last completed {{ $value | humanizeDuration }} ago, well past its interval. The scheduler catches throws to keep the ticker alive, so this means the task is hanging, failing on every tick, or has never succeeded since boot. Check `journalctl -u cogsworth -g task-failed` on cogsworth, then restart the unit if the task is wedged."
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
        # remoteWrite persists alert state and remoteRead restores it.
        # Without the pair, restartTriggers above resets every `for:` timer
        # on each rules edit, so a `for:` past the deploy cadence never
        # elapses. Same VictoriaMetrics as the datasource, over loopback.
        ExecStart = ''
          ${pkgs.victoriametrics}/bin/vmalert \
            -datasource.url=${cfg.datasourceUrl} \
            -notifier.url=${cfg.notifierUrl} \
            -remoteWrite.url=${cfg.datasourceUrl} \
            -remoteRead.url=${cfg.datasourceUrl} \
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
