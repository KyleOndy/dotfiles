{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.grafana;
in
{
  options.systemFoundry.monitoringStack.grafana = {
    enable = mkEnableOption "Grafana visualization and dashboards";

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Port for Grafana web interface";
    };

    domain = mkOption {
      type = types.str;
      default = "grafana.${parentCfg.domain}";
      description = "Domain name for Grafana (defaults to grafana.{parent domain})";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for Grafana domain";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_port = cfg.port;
          http_addr = "127.0.0.1";
          domain = cfg.domain;
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            access = "proxy";
            url = "http://${config.systemFoundry.monitoringStack.victoriametrics.listenAddress}:${toString config.systemFoundry.monitoringStack.victoriametrics.port}";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://${config.systemFoundry.monitoringStack.loki.listenAddress}:${toString config.systemFoundry.monitoringStack.loki.port}";
          }
        ];
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "default";
              type = "file";
              disableDeletion = false;
              updateIntervalSeconds = 10;
              allowUiUpdates = true;
              options = {
                path = "/etc/grafana-dashboards";
                foldersFromFilesStructure = false;
              };
            }
          ];
        };
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domain}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:${toString cfg.port}";
      provisionCert = cfg.provisionCert;
    };

    sops.secrets.grafana_admin_password = {
      owner = "grafana";
      group = "grafana";
    };

    services.grafana.settings.security.admin_password =
      "$__file{${config.sops.secrets.grafana_admin_password.path}}";

    environment.etc."grafana-dashboards/system-overview.json" = {
      source = ./dashboards/system-overview.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/node-exporter-full.json" = {
      source = ./dashboards/node-exporter-full.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/systemd-services.json" = {
      source = ./dashboards/systemd-services.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/zfs-storage.json" = {
      source = ./dashboards/zfs-storage.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/media-services.json" = {
      source = ./dashboards/media-services.json;
      mode = "0644";
    };
  };
}
