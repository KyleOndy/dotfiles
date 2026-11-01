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
          host = parentCfg.smtp.server;
          user = parentCfg.smtp.username;
          password = "$__file{${config.sops.secrets.monitoring_smtp_password.path}}";
          from_address = parentCfg.smtp.from;
          from_name = "Grafana Monitoring";
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "VictoriaMetrics";
            uid = "victoriametrics";
            type = "prometheus";
            access = "proxy";
            url = "http://${config.systemFoundry.monitoringStack.victoriametrics.listenAddress}:${toString config.systemFoundry.monitoringStack.victoriametrics.port}";
            isDefault = true;
          }
          {
            name = "Loki";
            uid = "loki";
            type = "loki";
            access = "proxy";
            url = "http://${config.systemFoundry.monitoringStack.loki.listenAddress}:${toString config.systemFoundry.monitoringStack.loki.port}";
          }
          {
            name = "Alertmanager";
            uid = "alertmanager";
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
          # The Jellyfin log alerts are vmalert rules over Loki recording rules
          # (loki.nix, vmalert.nix), so they reach Alertmanager and the advisor.
          # Grafana keeps a provisioned rule dropped from this file until a
          # deleteRules entry names its uid.
          rules.settings = {
            apiVersion = 1;
            deleteRules = [
              {
                orgId = 1;
                uid = "jellyfin-transcode-failure";
              }
              {
                orgId = 1;
                uid = "jellyfin-playback-error";
              }
            ];
          };
        };
      };
    };

    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
        };

    sops.secrets.monitoring_smtp_password.owner = "grafana";

    sops.secrets.grafana_admin_password = {
      owner = "grafana";
      group = "grafana";
    };

    # Grafana encrypts datasource and alerting secrets in its database with
    # this. nixpkgs shipped a default until 26.05 and now refuses to guess one,
    # because everyone who took the default shared it.
    sops.secrets.grafana_secret_key = {
      owner = "grafana";
      group = "grafana";
    };

    services.grafana.settings.security = {
      admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
      secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
      cookie_secure = true;
    };

    # Every file under dashboards/ is provisioned at the path it already has in
    # the tree, which is what foldersFromFilesStructure turns into Grafana
    # folders. Adding a dashboard is dropping in a file, with no edit here.
    environment.etc = listToAttrs (
      map (path: {
        name = "grafana-dashboards/${removePrefix "${toString ./dashboards}/" (toString path)}";
        value = {
          source = path;
          mode = "0644";
        };
      }) (lib.filesystem.listFilesRecursive ./dashboards)
    );

    # The plugin installer resolves grafana.com within seconds of start, and
    # network.target comes before tiger's DHCP lease and DNS.
    systemd.services.grafana = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
  };
}
