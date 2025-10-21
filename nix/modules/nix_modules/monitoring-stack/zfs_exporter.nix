{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.zfsExporter;
in
{
  options.systemFoundry.monitoringStack.zfsExporter = {
    enable = mkEnableOption "ZFS exporter for pool metrics collection";

    port = mkOption {
      type = types.port;
      default = 9134;
      description = "Port for ZFS exporter metrics endpoint";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    pools = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Specific ZFS pools to monitor (empty list monitors all pools)";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.prometheus.exporters.zfs = {
      enable = true;
      port = cfg.port;
      listenAddress = cfg.listenAddress;
      pools = cfg.pools;
    };
  };
}
