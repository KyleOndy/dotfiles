{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.nginxlogExporter;

  # Configuration file for prometheus-nginxlog-exporter
  exporterConfig = pkgs.writeText "nginxlog-exporter.yml" (
    builtins.toJSON {
      listen = {
        port = cfg.port;
        address = "127.0.0.1";
      };
      consul.enable = false;
      namespaces = [
        {
          name = "nginx";
          format = ''$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $request_time $server_name $scheme $upstream_response_time'';
          source = {
            files = [ "/var/log/nginx/access.log" ];
            # Enable file polling to tail the log file
            poll_interval_seconds = 1;
          };
          labels = {
            service = "nginx";
            host = config.networking.hostName;
          };
          # Relabel to add useful labels for filtering
          relabel_configs = [
            {
              target_label = "vhost";
              from = "server_name";
            }
            {
              target_label = "scheme";
              from = "scheme";
            }
          ];
          # Track upstream response time separately (backend latency)
          upstream_response_time_histogram = true;
          # Response time buckets in seconds
          histogram_buckets = [
            0.005
            0.01
            0.025
            0.05
            0.1
            0.25
            0.5
            1
            2.5
            5
            10
          ];
        }
      ];
    }
  );
in
{
  options.systemFoundry.monitoringStack.nginxlogExporter = {
    enable = mkEnableOption "prometheus-nginxlog-exporter for nginx access log analytics";

    port = mkOption {
      type = types.port;
      default = 4040;
      description = "Port for nginxlog-exporter metrics endpoint";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Add prometheus-compatible log format to nginx
    services.nginx.commonHttpConfig = mkAfter ''
      # Prometheus-friendly access log format with extended metrics
      # Fields: remote_addr, remote_user, time_local, request, status, body_bytes_sent,
      #         http_referer, http_user_agent, request_time, server_name, scheme, upstream_response_time
      log_format prometheus '$remote_addr - $remote_user [$time_local] '
                            '"$request" $status $body_bytes_sent '
                            '"$http_referer" "$http_user_agent" '
                            '$request_time $server_name $scheme $upstream_response_time';

      # Write access log in prometheus format
      access_log /var/log/nginx/access.log prometheus;
    '';

    # Run prometheus-nginxlog-exporter
    systemd.services.nginxlog-exporter = {
      description = "Prometheus exporter for nginx access logs";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "nginx.service"
      ];
      wants = [ "nginx.service" ];

      serviceConfig = {
        Type = "simple";
        User = "nginxlog-exporter";
        Group = "nginxlog-exporter";
        # Grant read access to nginx logs
        SupplementaryGroups = [ "nginx" ];
        ExecStart = ''
          ${pkgs.prometheus-nginxlog-exporter}/bin/prometheus-nginxlog-exporter \
            -config-file ${exporterConfig}
        '';
        Restart = "on-failure";
        RestartSec = "5s";
        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadOnlyPaths = [ "/var/log/nginx" ];
      };
    };

    users.users.nginxlog-exporter = {
      isSystemUser = true;
      group = "nginxlog-exporter";
      extraGroups = [ "nginx" ];
      description = "nginxlog-exporter service user";
    };

    users.groups.nginxlog-exporter = { };

    # Ensure nginx log directory has proper permissions
    systemd.tmpfiles.rules = [ "d /var/log/nginx 0755 nginx nginx -" ];
  };
}
