{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.alertmanager;
in
{
  options.systemFoundry.monitoringStack.alertmanager = {
    enable = mkEnableOption "Alertmanager for alert routing and management";

    port = mkOption {
      type = types.port;
      default = 9093;
      description = "Port for Alertmanager web interface and API";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    smtp = {
      server = mkOption {
        type = types.str;
        default = "london.mxroute.com:587";
        description = "SMTP server address (e.g., smtp.gmail.com:587)";
      };

      from = mkOption {
        type = types.str;
        default = "monitoring@ondy.org";
        description = "Email address to send alerts from";
      };

      to = mkOption {
        type = types.listOf types.str;
        default = [ "kyle@ondy.org" ];
        description = "Email addresses to send alerts to";
      };

      username = mkOption {
        type = types.str;
        default = "monitoring@ondy.org";
        description = "SMTP username for authentication";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing SMTP password";
      };
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    sops.secrets.monitoring_smtp_password = {
      mode = "0444";
    };

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = cfg.listenAddress;
      port = cfg.port;

      # Disable clustering for single-node deployment
      extraFlags = [
        "--cluster.listen-address="
        "--cluster.advertise-address=127.0.0.1:9094"
        "--web.external-url=https://vmalert.apps.ondy.org"
      ];

      configuration = {
        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
        };

        receivers = [
          (
            {
              name = "default";
            }
            // optionalAttrs (cfg.smtp.server != "") {
              email_configs = map (recipient: {
                to = recipient;
                send_resolved = true;
              }) cfg.smtp.to;
            }
          )
        ];
      }
      // optionalAttrs (cfg.smtp.server != "") {
        global = {
          smtp_smarthost = cfg.smtp.server;
          smtp_from = cfg.smtp.from;
          smtp_auth_username = cfg.smtp.username;
          smtp_auth_password_file = config.sops.secrets.monitoring_smtp_password.path;
        };
      };
    };
  };
}
