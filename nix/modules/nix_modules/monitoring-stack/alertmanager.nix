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

    domain = mkOption {
      type = types.str;
      default = "alertmanager.${parentCfg.domain}";
      description = "Domain name for the Alertmanager UI (defaults to alertmanager.{parent domain})";
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
        # Every "Silence" link in an alert email is built from this, so it has
        # to be Alertmanager's own hostname and it has to resolve off-network.
        "--web.external-url=https://${cfg.domain}"
      ];

      configuration = {
        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
          routes = [
            {
              # Provider (Hetzner) has documented Percentage Used >= 100 as benign
              # while Available Spare > threshold. Keep the alert visible in the UI
              # but don't email on each repeat_interval.
              match = {
                alertname = "SmartDriveEnduranceExceeded";
              };
              receiver = "null";
            }
          ];
        };

        receivers = [
          (
            {
              name = "default";
            }
            // optionalAttrs (parentCfg.smtp.server != "") {
              email_configs = map (recipient: {
                to = recipient;
                send_resolved = true;
              }) parentCfg.smtp.to;
            }
          )
          { name = "null"; }
        ];
      }
      // optionalAttrs (parentCfg.smtp.server != "") {
        global = {
          smtp_smarthost = parentCfg.smtp.server;
          smtp_from = parentCfg.smtp.from;
          smtp_auth_username = parentCfg.smtp.username;
          smtp_auth_password_file = config.sops.secrets.monitoring_smtp_password.path;
        };
      };
    };

    # Basic auth on every path, same as vmalert: the UI is not read-only, it
    # creates and expires silences. The loopback callers (vmalert's notifier,
    # tiger's upssched dispatcher) hit 127.0.0.1:9093 directly and never pass
    # through Caddy, so they are unaffected.
    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
          basicAuth = parentCfg.monitoringBasicAuth;
          basicAuthPaths = [ ]; # empty = protect all paths
        };
  };
}
