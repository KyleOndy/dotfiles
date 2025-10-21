{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.nodeExporter;
in
{
  options.systemFoundry.monitoringStack.nodeExporter = {
    enable = mkEnableOption "node_exporter for system metrics collection";

    port = mkOption {
      type = types.port;
      default = 9100;
      description = "Port for node_exporter metrics endpoint";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    enabledCollectors = mkOption {
      type = types.listOf types.str;
      default = [ "systemd" ];
      description = "Additional collectors to enable beyond the defaults";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      listenAddress = cfg.listenAddress;
      enabledCollectors = cfg.enabledCollectors;
    };
  };
}
