{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.vmagent;
in
{
  options.systemFoundry.monitoringStack.vmagent = {
    enable = mkEnableOption "vmagent for lightweight metrics collection";

    remoteWriteUrl = mkOption {
      type = types.str;
      description = "VictoriaMetrics remote write URL";
      example = "https://metrics.apps.ondy.org/api/v1/write";
    };

    bearerTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing bearer token for authentication (nginx hosts)";
    };

    basicAuth = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              description = "Basic auth username";
            };
            passwordFile = mkOption {
              type = types.path;
              description = "Path to file containing the basic auth password";
            };
          };
        }
      );
      default = null;
      description = "Basic auth credentials for remote write (Caddy hosts)";
    };

    scrapeConfigs = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Prometheus scrape configurations";
      example = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
            }
          ];
        }
      ];
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.vmagent = {
      enable = true;
      remoteWrite = {
        url = cfg.remoteWriteUrl;
      };
      prometheusConfig = {
        global = {
          scrape_interval = "15s";
        };
        scrape_configs = cfg.scrapeConfigs;
      };
      extraArgs =
        optionals (cfg.bearerTokenFile != null) [
          "-remoteWrite.bearerTokenFile=${cfg.bearerTokenFile}"
        ]
        ++ optionals (cfg.basicAuth != null) [
          "-remoteWrite.basicAuth.username=${cfg.basicAuth.username}"
          "-remoteWrite.basicAuth.passwordFile=${toString cfg.basicAuth.passwordFile}"
        ];
    };

    # Provide SSL CA certificate bundle for HTTPS remote write with DynamicUser
    # DynamicUser runs in an isolated environment without automatic access to system certs
    systemd.services.vmagent.serviceConfig.Environment = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
  };
}
