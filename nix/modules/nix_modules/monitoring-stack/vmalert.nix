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

        # The UPS behind tiger and the network gear, read from nut_exporter.
        # upssched also pushes UPSCommLost and UPSReplaceBattery straight to
        # Alertmanager, where the push inhibits the rule of the same name, so
        # those two rules speak only when upsmon cannot.
        - name: ups
          interval: 30s
          rules:
            # upsd fails the scrape while it has no data from the UPS, so `up`
            # is 0 with the exporter itself still running.
            - alert: UPSCommLost
              expr: up{host="tiger",job="nut"} == 0 and on(host) node_systemd_unit_state{host="tiger",name="prometheus-nut-exporter.service",state="active"} == 1
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "No data from the tiger UPS for 5 minutes"
                description: "nut_exporter is running but upsd has no data from the UPS, so upsmon cannot see a power failure either: tiger would never shut down and would crash when the battery ran out. The usual cause is the usbhid-ups reconnect loop; check journalctl -u upsdrv and upsc tiger@localhost."

            # InstanceDown covers the exporter being down. This covers the
            # scrape job going missing, or ups.status dropping out of a scrape
            # that still succeeds, either of which leaves this group blind.
            - alert: UPSStatusMissing
              expr: absent(network_ups_tools_ups_status{host="tiger",flag="OL"}) unless on() (up{host="tiger",job="nut"} == 0)
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "No UPS status series from tiger"
                description: "network_ups_tools_ups_status is missing while the nut scrape is not failing, so either the scrape job is gone from vmagent or ups.status is missing from nutVariables in nut-exporter.nix. Every other rule in the ups group is blind until it is back."

            # tiger runs vmalert, so once upssched has shut it down nothing is
            # left to evaluate this. It can only fire if that shutdown failed.
            - alert: UPSShutdownOverdue
              expr: network_ups_tools_ups_status{host="tiger",flag="OB"} == 1
              for: 3m
              labels:
                severity: critical
              annotations:
                summary: "tiger is still running on UPS battery"
                description: "The UPS has been on battery for 3 minutes and tiger has not shut down, so the upssched shutdown timer never fired or upsmon -c fsd failed. tiger is draining the battery the network gear needs. Check journalctl -t upssched -u upsmon, and shut tiger down by hand if mains is still out."

            - alert: UPSBatteryNotCharging
              expr: network_ups_tools_battery_charge{host="tiger"} < 80 and on(host) network_ups_tools_ups_status{host="tiger",flag="OL"} == 1
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "UPS battery at {{ $value }}% after an hour on mains"
                description: "The UPS is on line power but its battery has stayed under 80% for an hour, so it is not recharging. A battery near the end of its life does this before it sets RB."

            - alert: UPSRuntimeLow
              expr: network_ups_tools_battery_runtime{host="tiger"} < 600
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "UPS runtime estimate is {{ $value | humanizeDuration }}"
                description: "The UPS expects under 10 minutes on battery at the current load. Either the load has grown (ups.load) or the battery has lost capacity."

            - alert: UPSLoadHigh
              expr: network_ups_tools_ups_load{host="tiger"} > 80
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "UPS load is {{ $value }}%"
                description: "The UPS is above 80% of its rated load, which cuts runtime and leaves no headroom for a startup surge."

            - alert: UPSReplaceBattery
              expr: network_ups_tools_ups_status{host="tiger",flag="RB"} == 1
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "tiger UPS reports its battery needs replacing"
                description: "The UPS has set RB, usually after failing a self-test (ups-battery-test runs one on the first Monday of each month). Runtime on battery is no longer what battery.runtime claims."

            # 120V nominal, plus or minus 10%.
            - alert: UPSInputVoltageOutOfRange
              expr: network_ups_tools_input_voltage{host="tiger"} < 108 or network_ups_tools_input_voltage{host="tiger"} > 132
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "UPS input voltage is {{ $value }}V"
                description: "Mains at the UPS has been outside 108-132V for 5 minutes. The UPS is trimming or boosting to hold its output; a sustained sag or swell is a wiring or utility problem."

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
              expr: node_systemd_unit_state{host="tiger",name="seerr.service",state="active"} != 1
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
            # Sonarr reports a blocked item as importPending while it re-checks
            # it each minute, so the blocked series has gaps that would restart
            # `for:` too; max_over_time bridges them.
            #
            # download_status catches what the state list cannot: an item the
            # *arr warns on but leaves in importPending forever. Radarr retried
            # one unparseable mkv that way every 20s for over a week. The *arrs
            # mark every import they refuse with TrackedDownload.Warn(), and a
            # healthy importPending item reports status ok.
            - alert: SonarrImportBlocked
              expr: sum by (host) (max_over_time(sonarr_queue_total{download_state=~"importBlocked|importFailed|failedPending"}[30m]) or max_over_time(sonarr_queue_total{download_status=~"warning|error"}[30m])) > 0
              for: 24h
              labels:
                severity: warning
                service: sonarr
              annotations:
                summary: "Sonarr has {{ $value }} queue item(s) stuck importing"
                description: "Sonarr retries these every 60s and is still blocked, so they need a decision, not time. Open https://sonarr.tiger.infra.ondy.org/activity/queue and either manual-import or remove them. arr-queue-janitor removes and blocklists blocked items at 48h, but never touches one sitting in importPending."

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
              expr: sum by (host) (max_over_time(radarr_queue_total{download_state=~"importBlocked|importFailed|failedPending"}[30m]) or max_over_time(radarr_queue_total{download_status=~"warning|error"}[30m])) > 0
              for: 24h
              labels:
                severity: warning
                service: radarr
              annotations:
                summary: "Radarr has {{ $value }} queue item(s) stuck importing"
                description: "Radarr retries these every 60s and is still blocked, so they need a decision, not time. Open https://radarr.tiger.infra.ondy.org/activity/queue and either manual-import or remove them. arr-queue-janitor removes and blocklists blocked items at 48h, but never touches one sitting in importPending."

            - alert: LidarrQueueHigh
              expr: lidarr_queue_total > 50
              for: 4h
              labels:
                severity: warning
                service: lidarr
              annotations:
                summary: "Lidarr queue depth is high: {{ $value }} items"
                description: "Lidarr has more than 50 items in queue for 4+ hours"

            # importFailed and not just importBlocked: lidarr parks an
            # incomplete release here, where sonarr and radarr would say
            # importBlocked. Without it the whole group matches nothing.
            - alert: LidarrImportBlocked
              expr: sum by (host) (max_over_time(lidarr_queue_total{download_state=~"importBlocked|importFailed|failedPending"}[30m]) or max_over_time(lidarr_queue_total{download_status=~"warning|error"}[30m])) > 0
              for: 24h
              labels:
                severity: warning
                service: lidarr
              annotations:
                summary: "Lidarr has {{ $value }} queue item(s) stuck importing"
                description: "Lidarr retries these every 60s and is still blocked, so they need a decision, not time. Open https://lidarr.tiger.infra.ondy.org/activity/queue and either manual-import or remove them. arr-queue-janitor removes and blocklists blocked items at 48h, but never touches one sitting in importPending."

            # Each app's System > Status page: download client unreachable,
            # root folder missing, import lists failing. UpdateCheck is noise
            # where nixpkgs picks the version; the two indexer status checks
            # flap with Prowlarr's own backoff, and ProwlarrIndexersUnavailable
            # covers indexers instead.
            - alert: ArrHealthIssue
              expr: max by (host, job, source, type, message, wikiurl) (max_over_time({__name__=~"(sonarr|radarr|lidarr|prowlarr|bazarr)_system_health_issues",source!~"UpdateCheck|IndexerStatusCheck|IndexerLongTermStatusCheck"}[1h])) == 1
              for: 2h
              labels:
                severity: warning
              annotations:
                summary: "{{ $labels.job }}: {{ $labels.message }}"
                description: "{{ $labels.job }} has reported this {{ $labels.type }} from {{ $labels.source }} for 2 hours. {{ $labels.wikiurl }}"

            - alert: ProwlarrIndexersUnavailable
              expr: sum by (host) (prowlarr_indexer_unavailable) * 2 > max by (host) (prowlarr_indexer_total)
              for: 2h
              labels:
                severity: warning
                service: prowlarr
              annotations:
                summary: "Prowlarr has more than half its indexers unavailable"
                description: "Searches and RSS reach too few indexers for grabs to work. Usually an expired API key or an indexer outage; see https://prowlarr.tiger.infra.ondy.org/settings/indexers"

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

            # A gauge and not increase() on a counter: a tar that will never
            # extract is retried every sweep, and the counter would report the
            # retries rather than the one file that needs a human.
            - alert: UntarDownloadsStuck
              expr: untar_downloads_stuck_archives > 0
              for: 30m
              labels:
                severity: warning
                service: sabnzbd
              annotations:
                summary: "untar-downloads left {{ $value }} archive(s) in place"
                description: "A .tar in /mnt/scratch-big/downloads/complete would not extract, so the job stays archived and the *arr keeps failing its import. Run `journalctl -u untar-downloads` for the tar error; a truncated or password-protected archive needs the release grabbing again."

            # absent() folded in: the timer writes this every 15 minutes, so a
            # missing series means the sweep is gone rather than merely late,
            # and a bare time() comparison would match nothing and stay quiet.
            - alert: UntarDownloadsStale
              expr: absent(untar_downloads_last_run_timestamp_seconds) or (time() - untar_downloads_last_run_timestamp_seconds > 6 * 3600)
              for: 30m
              labels:
                severity: warning
                service: sabnzbd
              annotations:
                summary: "untar-downloads has not swept in over 6 hours"
                description: "Releases that ship as a single .tar will sit unextracted and the *arr import queue will fill. Check `systemctl status untar-downloads.timer` on tiger."

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

            # trex runs 85-90% full in normal use, so the 15% default sits
            # inside its daily swing.
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{host="trex",fstype!~"tmpfs|fuse.*",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{host="trex",fstype!~"tmpfs|fuse.*",mountpoint!~"/Volumes/.*"} < 0.08) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 8% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{host="trex",fstype!~"tmpfs|fuse.*",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{host="trex",fstype!~"tmpfs|fuse.*",mountpoint!~"/Volumes/.*"} < 0.04) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 4% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            # Default disk space alerts for all other filesystems.
            # macOS mounts removable media, .dmg installers and network shares
            # under /Volumes; none of them are this host's storage to manage, and
            # a writable USB stick evades the readonly guard below.
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",host!="trex",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",host!="trex",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} < 0.15) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 15% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*",host!="trex",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*",host!="trex",mountpoint!="/mnt/media",mountpoint!~"/Volumes/.*"} < 0.10) and on(instance, device, mountpoint) node_filesystem_readonly == 0
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

            # The space rules above skip read-only filesystems, so a disk the
            # kernel remounts read-only after an error would drop out of them
            # silently. trex's sealed system volume is read-only by design.
            - alert: FilesystemReadOnly
              expr: node_filesystem_readonly{fstype!~"tmpfs|squashfs|nsfs|ramfs|overlay|fuse.*"} == 1 unless node_filesystem_readonly{fstype="apfs",mountpoint="/"}
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.mountpoint }} on {{ $labels.host }} is read-only"
                description: "{{ $labels.device }} at {{ $labels.mountpoint }} is mounted read-only, usually because the kernel remounted it after an I/O error. Writes there are failing. Check: journalctl -k | grep -iE 'remount|I/O error'"

            - alert: FilesystemDeviceError
              expr: node_filesystem_device_error{fstype!~"tmpfs|fuse.*|nsfs|ramfs"} == 1
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "node_exporter cannot stat {{ $labels.mountpoint }} on {{ $labels.host }}"
                description: "statfs on {{ $labels.mountpoint }} fails, so its free space is unknown and the disk space rules cannot fire for it. A hung NFS or SMB mount and a dying disk both look like this."

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

            # Any non-zero count fires: the overall SMART verdict above flips
            # only once a drive is already failing, and these are the leading
            # indicators. Same-batch drives in a single-parity pool are why
            # the bar is zero rather than a tolerance.
            - alert: SmartDriveSectorsFailing
              expr: smartctl_ata_attribute_raw{attribute_id=~"5|187|197|198"} > 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "REPLACE NOW: {{ $labels.host }}:{{ $labels.device }} {{ $labels.attribute_name }} = {{ $value }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} reports {{ $labels.attribute_name }} = {{ $value }}. This drive is failing and must be replaced now, not watched: drives with any non-zero reallocated, pending or uncorrectable count fail at many times the normal rate. Order a replacement today. Fit it in a free port and run `zpool replace <pool> <this-disk> <new-disk>` while this drive is still attached, so the pool keeps its redundancy during the resilver. Run: smartctl -a /dev/{{ $labels.device }}"

            - alert: SmartSelfTestFailed
              expr: smartctl_selftest_log_has_errors == 1
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "REPLACE NOW: SMART self-test failed on {{ $labels.host }}:{{ $labels.device }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} failed a SMART self-test: it could not read part of its own surface. This drive must be replaced now. Order a replacement today and `zpool replace` it while this drive is still attached. Run: smartctl -l selftest /dev/{{ $labels.device }}"

            - alert: SmartLinkCrcErrorsIncreasing
              expr: increase(smartctl_ata_attribute_raw{attribute_id="199"}[1d]) > 0
              labels:
                severity: warning
              annotations:
                summary: "SATA link errors on {{ $labels.host }}:{{ $labels.device }}"
                description: "Drive {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} logged {{ $value }} new UDMA CRC errors in 24h. This is the cable, port or backplane, not the platters: reseat or swap the SATA cable before replacing the drive."

            - alert: ZfsVdevErrors
              expr: zfs_vdev_errors > 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "ZFS {{ $labels.type }} errors on {{ $labels.host }}:{{ $labels.pool }}/{{ $labels.vdev }}"
                description: "ZFS counted {{ $value }} {{ $labels.type }} errors on {{ $labels.vdev }} in pool {{ $labels.pool }} on {{ $labels.host }}. ZFS repaired what it could from parity, but the drive returned bad or no data. Treat this drive as failing: check its SMART attributes, and if they are also non-zero, replace it now. Run: zpool status -v {{ $labels.pool }}"

            # Neither the ATA nor the NVMe branch of smartctl-exporter
            # produced data for a drive it scanned, so every alert above is
            # silently blind to it.
            - alert: SmartAttributesMissing
              expr: |
                smartctl_device_smart_healthy
                unless on(host, device) smartctl_ata_attribute_raw
                unless on(host, device) smartctl_nvme_critical_warning
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "No SMART attributes for {{ $labels.host }}:{{ $labels.device }}"
                description: "smartctl-exporter reports a health verdict for {{ $labels.device }} ({{ $labels.serial }}) on {{ $labels.host }} but no attributes, so the failure-predicting alerts cannot fire for it. Run: smartctl -a /dev/{{ $labels.device }}"

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

            # Linux only: node_exporter on darwin exports neither metric.
            - alert: HostOomKill
              expr: increase(node_vmstat_oom_kill[5m]) > 0
              labels:
                severity: warning
              annotations:
                summary: "The kernel OOM-killed a process on {{ $labels.host }}"
                description: "Something on {{ $labels.host }} was killed for memory. A service that restarts cleanly afterwards trips no other alert. Find the victim with: journalctl -k | grep -i 'killed process'"

            # cogsworth has no RTC and boots with the wrong time until NTP
            # syncs, so `for:` has to outlast that.
            - alert: HostClockNotSynchronising
              expr: node_timex_sync_status == 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Clock on {{ $labels.host }} is not synchronised"
                description: "The kernel reports the clock unsynchronised for 30 minutes. TLS, sops and sanoid snapshot names all trust it. Check: timedatectl timesync-status"


        # ZFS pool health and scrub freshness.
        #
        # Neither existed on any host before this group. SystemdServiceFailed
        # looks like it covers the scrub and does not: a oneshot that never
        # runs never enters `failed`, so a disabled timer, a misfire, or a
        # host that was down at the trigger are all invisible. The only
        # reliable signal is the absence of a recent success.
        #
        # Metric names matter here. zfs_zpool_* was renamed zfs_pool_* and
        # the poolname label became pool (DASHBOARD_CONVENTIONS.md, "Exporter
        # Metric Naming Mismatches"), so a rule written from memory matches
        # nothing, forever, silently.
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
              expr: absent(zfs_dataset_snapshot_count{host="pika",dataset="tank/photos"}) or absent(zfs_dataset_snapshot_count{host="pika",dataset="tank/backups"}) or absent(zfs_dataset_snapshot_count{host="pika",dataset="tank/projects"})
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Backup dataset {{ $labels.dataset }} is gone from pika"
                description: "{{ $labels.dataset }} reports no snapshot metrics at all on pika. Either the dataset was destroyed, or zfs-snapshot-exporter is not writing. Both leave every other rule in this group matching nothing. Check `zfs list -r tank` and `systemctl status zfs-snapshot-exporter` on pika."

            - alert: BackupReplicaEmpty
              expr: zfs_dataset_snapshot_count{host="pika",dataset=~"tank/(photos|backups|projects)"} == 0
              for: 2h
              labels:
                severity: critical
              annotations:
                summary: "Backup dataset {{ $labels.dataset }} on pika holds no snapshots"
                description: "{{ $labels.dataset }} exists on pika but holds zero snapshots, so the second copy of this data does not exist. sanoid on pika prunes and never creates, so it cannot refill this on its own. Check syncoid and pika's retention against tiger's."

            - alert: BackupReplicaStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="pika",dataset=~"tank/(photos|backups|projects)"} > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Backup of {{ $labels.dataset }} on pika is over 36 hours old"
                description: "The newest snapshot in {{ $labels.dataset }} on pika is more than 36 hours old, against a daily syncoid timer. If the matching storage dataset on tiger is fresh, replication is the broken end: check `systemctl status syncoid-storage-*` on pika."

            - alert: BackupReplicaCriticallyStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="pika",dataset=~"tank/(photos|backups|projects)"} > 72 * 3600
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Backup of {{ $labels.dataset }} on pika is over 72 hours old"
                description: "The newest snapshot in {{ $labels.dataset }} on pika is more than 72 hours old. Three daily runs have now failed to land anything. Treat the second copy as not current."

            # tiger's own snapshots, because pika can only be as fresh as
            # what it is pulling from.
            - alert: BackupSourceSnapshotsStale
              expr: time() - zfs_dataset_latest_snapshot_timestamp_seconds{host="tiger",dataset=~"storage/(photos|backups|projects)"} > 36 * 3600
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Snapshots of {{ $labels.dataset }} on tiger are over 36 hours old"
                description: "sanoid on tiger has not made a snapshot of {{ $labels.dataset }} in over 36 hours, against an hourly-and-daily policy. pika replicates snapshots and creates none of its own, so this staleness reaches the backup too. Check `systemctl status sanoid` on tiger."

            # The rules above see a chain that stopped. These three see
            # history being taken away while new snapshots keep arriving.
            - alert: BackupSnapshotsMassLoss
              expr: zfs_dataset_snapshot_count{host=~"tiger|pika",dataset=~"(storage|tank)/(photos|backups|projects)"} < 0.5 * max_over_time(zfs_dataset_snapshot_count{host=~"tiger|pika",dataset=~"(storage|tank)/(photos|backups|projects)"}[3d])
              for: 10m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.dataset }} on {{ $labels.host }} lost over half its snapshots"
                description: "{{ $labels.dataset }} on {{ $labels.host }} holds {{ $value }} snapshots, under half its 3-day high. sanoid prunes a few per period, never half, so something destroyed them. Read `zpool history -il` on {{ $labels.host }} for the destroys. If it is tiger, stop the next syncoid run on pika until you know why: pika still holds what tiger lost."

            # used, not referenced: it counts snapshot space, so it drops when
            # history is destroyed rather than when files are deleted, which
            # snapshots absorb. projects is left out because emptying it is
            # its lifecycle: a shipped project's last snapshot ageing out is
            # meant to free most of the dataset.
            - alert: BackupDatasetShrank
              expr: zfs_dataset_used_bytes{host=~"tiger|pika",name=~"(storage|tank)/(photos|backups)"} < 0.8 * max_over_time(zfs_dataset_used_bytes{host=~"tiger|pika",name=~"(storage|tank)/(photos|backups)"}[3d])
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "{{ $labels.name }} on {{ $labels.host }} shrank by over 20% in 3 days"
                description: "{{ $labels.name }} on {{ $labels.host }} uses under 80% of its 3-day high. These datasets only grow, and space comes back only as snapshots go. A monthly or yearly prune on tiger releasing a long-deleted tree can do this once; anything else means snapshots were destroyed. Compare `zfs list -t snapshot` against BackupSnapshotsMassLoss and read `zpool history -il` on {{ $labels.host }}."

            # A snapshot dated ahead pins latest_snapshot_timestamp in the
            # future, so BackupReplicaStale and BackupSourceSnapshotsStale go
            # quiet until the wall clock catches up with it.
            - alert: BackupSnapshotInFuture
              expr: zfs_dataset_latest_snapshot_timestamp_seconds{host=~"tiger|pika",dataset=~"(storage|tank)/(photos|backups|projects)"} - time() > 3600
              for: 10m
              labels:
                severity: critical
              annotations:
                summary: "Newest snapshot of {{ $labels.dataset }} on {{ $labels.host }} is dated in the future"
                description: "The newest snapshot of {{ $labels.dataset }} on {{ $labels.host }} is {{ $value | humanizeDuration }} ahead of now, so the staleness rules for it cannot fire. pika takes creation times from tiger's stream, so check tiger's clock first (`timedatectl`), then find the snapshot with `zfs list -t snapshot -o name,creation -s creation {{ $labels.dataset }}`."

        # The offsite tier, tier 3 of docs/backup-strategy.md. Same ordering
        # as backup_replication above: absence first, because a push that
        # never runs publishes nothing to be stale about.
        #
        # Two prefixes, not three. tank/projects is replicated but never
        # pushed to the archive bucket, so it has no s3-archive-push unit and
        # therefore no prefix label to match on. Every rule here is keyed on
        # a series the push units emit, so its absence is silent rather than
        # a permanently firing alert. Adding a projects prefix here without
        # first adding the push unit on pika would invert that.
        #
        # The project offsite copy goes to a different bucket, pushed by hand
        # from trex, and is not watched here at all. Nothing off-fleet is.
        # See the backup doc's What is left.
        #
        # These rules go quiet during an initial seed, which legitimately runs
        # for days before recording a first success. S3ArchivePushStale also
        # stays quiet for as long as a push is genuinely running. For anything
        # else that outlives a threshold here, reach for a silence rather than
        # a lower number.
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

            # The unless guard separates "the push is dead" from "the push is
            # still running". s3-archive-push writes its metrics only after
            # the sync returns, so last_success on its own reads a 30-hour
            # bulk import as a 30-hour outage; against the 2MB/s cap a push
            # carrying one legitimately outlives the 36h threshold.
            - alert: S3ArchivePushStale
              expr: |-
                (time() - s3_archive_push_last_success_timestamp_seconds{host="pika"} > 36 * 3600)
                unless on (prefix)
                label_replace(
                  node_systemd_unit_state{host="pika",state="active",name=~"s3-archive-push-.*\\.service"} == 1,
                  "prefix", "$1", "name", "s3-archive-push-(.*)\\.service")
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "Offsite push of {{ $labels.prefix }}/ is over 36 hours old"
                description: "The last clean sync of {{ $labels.prefix }}/ to the archive bucket is more than 36 hours old and no push is running now, against a daily timer. pika still holds the second copy, so this is not yet data loss, only loss of the offsite one. Check `journalctl -u s3-archive-push-{{ $labels.prefix }}` on pika."

            - alert: S3ArchivePushCriticallyStale
              expr: time() - s3_archive_push_last_success_timestamp_seconds{host="pika"} > 96 * 3600
              for: 1h
              labels:
                severity: critical
              annotations:
                summary: "Offsite push of {{ $labels.prefix }}/ is over 96 hours old"
                description: "Four daily runs have failed to complete a sync of {{ $labels.prefix }}/. Treat the offsite copy as not current: anything imported since then exists only in the house."

            # Fires on an initial seed too, which is 100% by definition.
            - alert: S3ArchivePushMassUpload
              expr: s3_archive_push_uploaded_objects{host="pika"} > 0.05 * s3_archive_push_source_objects{host="pika"}
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Offsite push rewrote {{ $value }} objects under {{ $labels.prefix }}/"
                description: "The last push of {{ $labels.prefix }}/ uploaded more than 5% of the prefix's objects. A bulk import explains it. Otherwise the source was rewritten under the push (encryption, a mass touch, a wrong mount), and every overwrite starts the good version's noncurrent clock. Read `journalctl -u s3-archive-push-{{ $labels.prefix }}` on pika and compare the tree against a snapshot on tiger before the next run."

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

        # trex pushes ~/src as git bundles into storage/backups. A fail-safe,
        # so one permissive warning and no never-succeeded rule.
        - name: git_backup
          interval: 60s
          rules:
            # Wall time alone would fire on a laptop shut for a fortnight, so
            # the guard counts awake time: one `up` sample per 15s scrape
            # (darwin_modules/monitoring-agent.nix), none while asleep.
            # last_over_time keeps a firing alert from resolving on each sleep.
            - alert: GitReposBackupStale
              expr: |-
                (time() - last_over_time(backup_git_repos_last_success_timestamp_seconds{host="trex"}[1d]) > 3 * 86400)
                and on (host)
                (count_over_time(up{host="trex",job="node"}[3d]) * 15 > 8 * 3600)
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "trex has not backed up ~/src in over 3 days"
                description: "backup-git-repos has not pushed to tiger in over 3 days, while trex was awake for more than 8 of them, against four runs a day. Check ~/Library/Logs/backup-git-repos.log on trex, then run `launchctl kickstart gui/$(id -u)/org.ondy.backup-git-repos`."

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

        # Read from caddy-cert-probe, which asks Caddy for every cert it is
        # configured to obtain. Caddy starts renewing with a third of the
        # lifetime left (certmagic DefaultRenewalWindowRatio), so a quarter
        # left means renewal has been failing for a twelfth of the lifetime:
        # about a week on a 90 day cert. Caddy keeps serving a cert after it
        # expires, so the probe still sees it.
        - name: tls_certificates
          interval: 60s
          rules:
            - alert: TLSCertExpired
              expr: tls_cert_not_after_timestamp_seconds < time()
              labels:
                severity: critical
              annotations:
                summary: "TLS cert for {{ $labels.name }} on {{ $labels.host }} has expired"
                description: "Caddy is serving an expired cert for {{ $labels.name }}, so every client rejects it. The renewal error is in journalctl -u caddy | grep tls.renew."

            - alert: TLSCertRenewalOverdue
              expr: (tls_cert_not_after_timestamp_seconds - time()) / (tls_cert_not_after_timestamp_seconds - tls_cert_not_before_timestamp_seconds) < 0.25 and tls_cert_not_after_timestamp_seconds >= time()
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "TLS cert for {{ $labels.name }} on {{ $labels.host }} is overdue for renewal"
                description: "{{ $labels.name }} has under a quarter of its lifetime left, and Caddy should have renewed it at a third. The ACME error is in journalctl -u caddy | grep tls.renew."

            - alert: TLSCertProbeFailing
              expr: tls_cert_probe_success == 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "No cert served for {{ $labels.name }} on {{ $labels.host }}"
                description: "A TLS handshake to 127.0.0.1:443 with SNI {{ $labels.name }} returned no cert, so its expiry is unknown. Caddy may never have obtained one; check journalctl -u caddy | grep {{ $labels.name }}."

            # The three rules above go quiet if the probe stops writing.
            - alert: TLSCertProbeStale
              expr: (time() - tls_cert_probe_timestamp_seconds > 3600) or (count by (host) (caddy_config_last_reload_successful) unless count by (host) (tls_cert_probe_timestamp_seconds))
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "TLS cert probe has not run on {{ $labels.host }}"
                description: "{{ $labels.host }} runs Caddy but has no cert expiry metrics from the last hour, so TLSCertExpired cannot fire there. Check systemctl status caddy-cert-probe.timer caddy-cert-probe.service."

        # SystemdServiceFailed already catches a run that exits non-zero. These
        # two cover what it cannot see: a run that succeeds while fetching
        # nothing, and a sweeper that dies and freezes the gauge the first rule
        # reads. Ordering matters, so the sweeper rule fires first at 48h and
        # answers "is the metric even live" before the stall rule speaks.
        - name: audio_language
          interval: 60s
          rules:
            - alert: AudioLanguageSweepStale
              expr: time() - media_audio_sweep_timestamp_seconds > 172800
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Audio language sweep has not run in 48h on {{ $labels.host }}"
                description: "The sweep writes every media_audio_* metric, so while it is down MediaAudioNotEnglish below is reading a stale count rather than the library as it stands. Fix this one first: systemctl status audio-language-sweep on {{ $labels.host }}."

            - alert: MediaAudioNotEnglish
              expr: media_audio_no_english_file > 0
              for: 1h
              labels:
                severity: warning
              annotations:
                summary: "No English audio: {{ $labels.path }}"
                description: >-
                  A release can parse clean on its name and still carry audio
                  in another language, which is only visible in the container.
                  One alert per file, grouped by alertname into a single mail.
                  A title whose own originalLanguage is not English is skipped,
                  so this is a file that should have English and does not.
                  Import-time verdicts:
                  `journalctl -t audio-language-check | grep FAIL` on
                  {{ $labels.host }}, and the sweep logs every path it flags
                  under the audio-language-sweep unit. The sweep names at most
                  50 files as series and says so in its log when it truncates;
                  media_audio_no_english_files carries the full count.

            - alert: MediaAudioUnverified
              expr: media_audio_unverified_files > 10
              for: 6h
              labels:
                severity: warning
              annotations:
                summary: "{{ $value }} files carry no language tag whisper could settle"
                description: >-
                  These are neither confirmed English nor confirmed wrong: the
                  sample vote came back split or silent, which is what a file
                  with no dialogue in the sampled windows looks like. Harmless
                  in small numbers; a jump means either a new source is
                  stripping language tags or the whisper model is missing and
                  every detection is failing open.

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
                  Run `yt-dlp -F <any channel url>` on {{ $labels.host }}
                  first; what it prints splits the two failure modes. A full
                  ladder up to 2160p means extraction is healthy and the media
                  fetch is what broke: every download returns HTTP 403 while
                  the run still exits 0. That is YouTube blocking whichever
                  player client yt-dlp defaults to, and the fix is a newer
                  yt-dlp rather than any config change. On 2026-08-17 it was
                  android_vr, dropped from the defaults upstream in 2026.08.19.
                  If instead the only media format offered is 18 (640x360), a
                  client is being served SABR-only and itag 18 is the one
                  format exempt from the PO token check. That was spring 2026,
                  and it was self-inflicted: player_client was pinned to "web",
                  and unpinning it is what restored 2160p. So do not reach for
                  a player_client pin here; the default set is what upstream
                  maintains. A PO token provider (bgutil, recoverable from git
                  0dc712f8) is the fallback if the defaults ever need one.
                  Genuine rate limiting looks different and shows HTTP 429. A
                  quiet week across all channels is also possible, so confirm
                  against ytdl_sub_videos_total before digging.

            # Not > 0: a members-only video and the odd transient refusal are
            # normal. 25 is roughly "a whole channel was wiped", against the 63
            # seen on 2026-08-11 when three channels fetched nothing at all.
            - alert: YtdlSubBotBlocked
              expr: sum by (host) (sum_over_time(ytdl_sub:bot_blocked_lines:count5m[26h])) > 25
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "YouTube bot check refused {{ $value }} downloads on {{ $labels.host }}"
                description: >-
                  The wall comes down partway into a run and then blocks every
                  channel after it, so the run still fetches plenty and exits
                  as it always does. Neither SystemdServiceFailed nor
                  YtdlSubStalled can see this. The count follows refusal log
                  lines, and yt-dlp retries each video several times, so it
                  overstates the videos actually lost. For which channels lost
                  out, read the Download Summary table at the end of the run:
                  `journalctl -u ytdl-sub-youtube -o cat | grep -A40 "Download
                  Summary"`. Channels showing 0 in the final column fetched
                  nothing. Subscription order is shuffled per run, so a channel
                  blocked one night is usually collected the next; the same
                  channel starving several nights running is the real signal.

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
                time() - cogsworth_job_last_success_timestamp_seconds{task=~"birds-poll|display-loop|light-loop|presence-broadcast|scheduled-reboot|sms-poll|weather-poll|webcal-sync"} > 3600
                or
                time() - cogsworth_job_last_success_timestamp_seconds{task=~"immich-sync|gphotos-sync"} > 86400
              for: 15m
              labels:
                severity: warning
                service: cogsworth
              annotations:
                summary: "Cogsworth job {{ $labels.task }} has not succeeded in {{ $value | humanizeDuration }}"
                description: "Background task {{ $labels.task }} last completed {{ $value | humanizeDuration }} ago, well past its interval. The scheduler catches throws to keep the ticker alive, so this means the task is hanging, failing on every tick, or has never succeeded since boot. Check `journalctl -u cogsworth -g task-failed` on cogsworth, then restart the unit if the task is wedged."

        # unpoller reports the controller's view, so a device that drops off
        # stops being reported rather than reporting down. The site-level
        # counters are the only place an absence becomes a number.
        - name: unifi
          interval: 60s
          rules:
            - alert: UnifiDeviceDisconnected
              expr: unpoller_site_disconnected > 0
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "{{ $value }} adopted UniFi {{ $labels.subsystem }} device(s) disconnected"
                description: "The controller has adopted devices it cannot reach on the {{ $labels.subsystem }} subsystem. A switch or AP that is deliberately unplugged holds this alert open, so silence it rather than lowering the threshold. `ssh tiger 'curl -s localhost:9130/metrics | grep unpoller_device_uptime'` lists what is still reporting."

            - alert: UnifiWanLatencyHigh
              expr: unpoller_site_latency_seconds{subsystem="www"} > 0.15
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "WAN latency is {{ $value | humanizeDuration }}"
                description: "The gateway's own latency probe is above 150ms against a ~17ms baseline. Everything served off tiger stays fast on the LAN; this is what the public aliases and any offsite push see."

            # `intenet` is upstream's spelling in unpoller, not a typo here.
            - alert: UnifiInternetDropping
              expr: increase(unpoller_site_intenet_drops_total[1h]) > 3
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "WAN dropped {{ $value }} times in the last hour"
                description: "The gateway recorded repeated internet drops. The S3 archive push and both public cert renewals depend on this link."

        # The stack watching itself. `up` covers a process that stops
        # answering; these cover the ones that answer and still move no data.
        - name: monitoring_stack
          interval: 60s
          rules:
            # A 200 that parses to nothing still sets up=1. This is the failure
            # that hid the cogsworth app scrape for a month.
            - alert: ScrapeReturnedNoSamples
              expr: scrape_samples_scraped == 0 and on(job, instance, host) up == 1
              for: 30m
              labels:
                severity: warning
              annotations:
                summary: "Scrape job {{ $labels.job }} on {{ $labels.host }} returns no samples"
                description: "The target answers and `up` is 1, but every scrape parses to zero series, so every alert and panel built on this job is silently empty rather than broken. The usual cause is the wrong path: an SPA catch-all or an HTML error page returns 200 with no metrics. Check the endpoint by hand with curl."

            - alert: VictoriaMetricsIngestStalled
              expr: sum(rate(vm_rows_inserted_total[10m])) == 0
              for: 15m
              labels:
                severity: critical
              annotations:
                summary: "VictoriaMetrics has ingested no rows for 15 minutes"
                description: "Nothing is landing in the TSDB, so every metrics alert in this file is evaluating against a frozen series set and will not fire. Check `systemctl status victoriametrics vmagent` on tiger."

            - alert: VmagentRemoteWriteFailing
              expr: sum(rate(vmagent_remotewrite_errors_total[10m])) > 0
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "vmagent is failing to remote-write"
                description: "tiger's vmagent cannot deliver to VictoriaMetrics. It buffers on disk first, so a short outage is invisible; sustained failure ends in dropped samples."

            - alert: LokiRulerDown
              expr: absent_over_time(loki:ruler_heartbeat[15m])
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Loki ruler has stopped feeding VictoriaMetrics"
                description: >-
                  Every log-derived alert reads a series the ruler mints from
                  LogQL and remote-writes here, so while this fires none of
                  them can fire either, and the logs they watch look quiet
                  rather than unwatched. The heartbeat is a constant evaluated
                  every minute, so its absence means the ruler, its
                  remote_write, or Loki itself has stopped. Check `systemctl
                  status loki` on tiger, then `curl -s
                  localhost:3100/metrics | grep loki_prometheus_rule` for
                  evaluation failures.

            - alert: VmagentScrapesFailing
              expr: rate(vm_promscrape_scrapes_failed_total[10m]) > 0
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "vmagent scrapes are failing on {{ $labels.host }}"
                description: "One or more targets are erroring on scrape. InstanceDown catches a target that is fully down; this catches timeouts and malformed exposition that leave `up` flapping instead."

            - alert: LokiPushFailing
              expr: sum(rate(loki_request_duration_seconds_count{route="loki_api_v1_push",status_code=~"5.."}[10m])) > 0
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "Loki is rejecting log pushes with 5xx"
                description: "Alloy cannot deliver logs. Every Loki-backed panel and the two Grafana jellyfin alerts go blind while this lasts."

            - alert: AlloyDroppingEntries
              expr: sum by (reason) (rate(loki_write_dropped_entries_total[15m])) > 0
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "alloy is dropping log entries ({{ $labels.reason }})"
                description: "Log lines are being discarded before they reach Loki. `rate_limited` means Loki's ingestion limit; `line_too_long` means a single entry exceeded the max; `ingester_error` means Loki refused them. Entries dropped here are gone."

            # A rule whose query errors can never fire, and vmalert only logs
            # it. `for:` rides out a VictoriaMetrics restart on deploy.
            - alert: VmalertRuleErroring
              expr: sum by (group, alertname) (increase(vmalert_alerting_rules_errors_total[5m])) > 0
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "vmalert cannot evaluate {{ $labels.alertname }}"
                description: "Every evaluation of {{ $labels.alertname }} in group {{ $labels.group }} has errored for 15 minutes, so it cannot fire. Either VictoriaMetrics is not answering or the expression is broken: journalctl -u vmalert | grep {{ $labels.alertname }}"

            # Only tiger's own vmagent is scraped, so this cannot see the
            # agents on pika and cogsworth.
            - alert: VmagentDroppingData
              expr: sum by (host) (increase(vm_persistentqueue_bytes_dropped_total[5m])) > 0
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "vmagent on {{ $labels.host }} is dropping buffered samples"
                description: "The persistent queue is full and vmagent is discarding the oldest data, so those samples are lost for good. VictoriaMetrics has been unreachable for longer than the queue can hold; check VmagentRemoteWriteFailing and systemctl status victoriametrics."

            - alert: AlloyComponentUnhealthy
              expr: sum by (host, health_type) (alloy_component_controller_running_components{health_type!="healthy"}) > 0
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "alloy on {{ $labels.host }} has {{ $value }} {{ $labels.health_type }} component(s)"
                description: "A component that is not healthy has usually stopped shipping its logs. The component and its error are on alloy's UI page, or in journalctl -u alloy."
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
