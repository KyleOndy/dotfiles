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
        default = "";
        description = "SMTP server address (e.g., smtp.gmail.com:587)";
      };

      from = mkOption {
        type = types.str;
        default = "";
        description = "Email address to send alerts from";
      };

      username = mkOption {
        type = types.str;
        default = "";
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
    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = cfg.listenAddress;
      port = cfg.port;

      configuration = {
        global = mkIf (cfg.smtp.server != "") {
          smtp_smarthost = cfg.smtp.server;
          smtp_from = cfg.smtp.from;
          smtp_auth_username = cfg.smtp.username;
          smtp_auth_password_file = mkIf (cfg.smtp.passwordFile != null) (toString cfg.smtp.passwordFile);
        };

        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
        };

        receivers = [
          {
            name = "default";
            email_configs = mkIf (cfg.smtp.server != "") [
              {
                to = cfg.smtp.from;
              }
            ];
          }
        ];
      };
    };
  };
}
