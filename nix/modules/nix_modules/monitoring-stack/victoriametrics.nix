{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.victoriametrics;
in
{
  options.systemFoundry.monitoringStack.victoriametrics = {
    enable = mkEnableOption "VictoriaMetrics metrics storage";

    port = mkOption {
      type = types.port;
      default = 8428;
      description = "Port for VictoriaMetrics HTTP API";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    retentionPeriod = mkOption {
      type = types.int;
      default = parentCfg.retention.metrics;
      description = "Days to retain metrics (defaults to parent retention.metrics)";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.victoriametrics = {
      enable = true;
      listenAddress = "${cfg.listenAddress}:${toString cfg.port}";
      retentionPeriod = cfg.retentionPeriod;
    };
  };
}
