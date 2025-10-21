{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.nginxExporter;
in
{
  options.systemFoundry.monitoringStack.nginxExporter = {
    enable = mkEnableOption "nginx-prometheus-exporter for monitoring nginx";

    port = mkOption {
      type = types.port;
      default = 9113;
      description = "Port for nginx-prometheus-exporter";
    };

    nginxStubStatusUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:80/nginx_status";
      description = "URL to nginx stub_status endpoint";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Enable nginx stub_status module
    services.nginx.statusPage = true;

    # Run nginx-prometheus-exporter
    systemd.services.nginx-exporter = {
      description = "Prometheus exporter for nginx metrics";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "nginx.service"
      ];
      wants = [ "nginx.service" ];

      serviceConfig = {
        Type = "simple";
        User = "nginx-exporter";
        Group = "nginx-exporter";
        ExecStart = ''
          ${pkgs.prometheus-nginx-exporter}/bin/nginx-prometheus-exporter \
            -nginx.scrape-uri=${cfg.nginxStubStatusUrl} \
            -web.listen-address=:${toString cfg.port}
        '';
        Restart = "on-failure";
        RestartSec = "5s";
        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    users.users.nginx-exporter = {
      isSystemUser = true;
      group = "nginx-exporter";
      description = "nginx-exporter service user";
    };

    users.groups.nginx-exporter = { };
  };
}
