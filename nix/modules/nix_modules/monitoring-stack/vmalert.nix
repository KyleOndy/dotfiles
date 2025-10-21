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
            - alert: SystemdServiceFailed
              expr: node_systemd_unit_state{state="failed"} == 1
              for: 1m
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

        # Disk space monitoring
        - name: disk_space
          interval: 60s
          rules:
            - alert: DiskSpaceLow
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*"} < 0.15) and on(instance, device, mountpoint) node_filesystem_readonly == 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}:{{ $labels.mountpoint }}"
                description: "Disk space is below 15% on {{ $labels.instance }} at {{ $labels.mountpoint }} ({{ $labels.device }}). Current: {{ $value | humanizePercentage }}"

            - alert: DiskSpaceCritical
              expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.*"} < 0.10) and on(instance, device, mountpoint) node_filesystem_readonly == 0
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
              expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.85
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "High memory usage on {{ $labels.instance }}"
                description: "Memory usage is above 85% on {{ $labels.instance }}. Current: {{ $value | humanizePercentage }}"

            - alert: HighMemoryUsageCritical
              expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.95
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Critical memory usage on {{ $labels.instance }}"
                description: "Memory usage is above 95% on {{ $labels.instance }}. Current: {{ $value | humanizePercentage }}"

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
