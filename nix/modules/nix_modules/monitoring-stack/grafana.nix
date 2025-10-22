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
        smtp = {
          enabled = true;
          host = config.systemFoundry.monitoringStack.alertmanager.smtp.server;
          user = config.systemFoundry.monitoringStack.alertmanager.smtp.username;
          password = "$__file{${config.sops.secrets.monitoring_smtp_password.path}}";
          from_address = config.systemFoundry.monitoringStack.alertmanager.smtp.from;
          from_name = "Grafana Monitoring";
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
          {
            name = "Alertmanager";
            type = "alertmanager";
            access = "proxy";
            url = "http://${config.systemFoundry.monitoringStack.alertmanager.listenAddress}:${toString config.systemFoundry.monitoringStack.alertmanager.port}";
            jsonData = {
              implementation = "prometheus";
              handleGrafanaManagedAlerts = true;
            };
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
                foldersFromFilesStructure = true;
              };
            }
          ];
        };
        alerting = {
          contactPoints.settings = {
            apiVersion = 1;
            contactPoints = [
              {
                orgId = 1;
                name = "email";
                receivers = [
                  {
                    uid = "email-kyle";
                    type = "email";
                    settings = {
                      addresses = "kyle@ondy.org";
                    };
                    disableResolveMessage = false;
                  }
                ];
              }
            ];
          };
          policies.settings = {
            apiVersion = 1;
            policies = [
              {
                orgId = 1;
                receiver = "email";
                group_by = [
                  "alertname"
                  "grafana_folder"
                ];
                group_wait = "10s";
                group_interval = "10s";
                repeat_interval = "1h";
              }
            ];
            resetPolicies = [ 1 ];
          };
        };
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domain}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:${toString cfg.port}";
      provisionCert = cfg.provisionCert;
      route53HostedZoneId = "Z0365859SHHFAPNR0QXN"; # ondy.org zone
    };

    sops.secrets.grafana_admin_password = {
      owner = "grafana";
      group = "grafana";
    };

    services.grafana.settings.security.admin_password =
      "$__file{${config.sops.secrets.grafana_admin_password.path}}";

    # System dashboards
    environment.etc."grafana-dashboards/system/system-overview.json" = {
      source = ./dashboards/system/system-overview.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/system/node-exporter-full.json" = {
      source = ./dashboards/system/node-exporter-full.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/system/systemd-services.json" = {
      source = ./dashboards/system/systemd-services.json;
      mode = "0644";
    };

    # Storage dashboards
    environment.etc."grafana-dashboards/storage/zfs-storage.json" = {
      source = ./dashboards/storage/zfs-storage.json;
      mode = "0644";
    };

    # Network dashboards
    environment.etc."grafana-dashboards/network/nginx-exporter.json" = {
      source = ./dashboards/network/nginx-exporter.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/network/nginx-log-metrics.json" = {
      source = ./dashboards/network/nginx-log-metrics.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/network/nginx-vhost-details.json" = {
      source = ./dashboards/network/nginx-vhost-details.json;
      mode = "0644";
    };

    # Application dashboards
    environment.etc."grafana-dashboards/applications/media-services.json" = {
      source = ./dashboards/applications/media-services.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/applications/youtube-downloader-operational.json" = {
      source = ./dashboards/applications/youtube-downloader-operational.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/applications/youtube-downloader-errors.json" = {
      source = ./dashboards/applications/youtube-downloader-errors.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/applications/youtube-downloader-performance.json" = {
      source = ./dashboards/applications/youtube-downloader-performance.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/applications/youtube-downloader-channel.json" = {
      source = ./dashboards/applications/youtube-downloader-channel.json;
      mode = "0644";
    };

    environment.etc."grafana-dashboards/applications/youtube-downloader-alerts.json" = {
      source = ./dashboards/applications/youtube-downloader-alerts.json;
      mode = "0644";
    };
  };
}
