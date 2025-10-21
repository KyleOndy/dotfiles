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
      description = "Path to file containing bearer token for authentication";
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
        basicAuthPasswordFile = cfg.bearerTokenFile;
      };
      prometheusConfig = {
        global = {
          scrape_interval = "15s";
        };
        scrape_configs = cfg.scrapeConfigs;
      };
    };
  };
}
