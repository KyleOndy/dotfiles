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
      default = [
        "systemd"
        "textfile"
      ];
      description = "Additional collectors to enable beyond the defaults";
    };

    textfileDirectory = mkOption {
      type = types.str;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "Directory for textfile collector to read .prom files from";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Producers join `textfile` and run as their own users. The sticky bit
    # stops one from replacing or deleting another's file, so a producer that
    # still runs as root must write through mktemp and rename, never through a
    # predictable name another member could plant a symlink at.
    users.groups.textfile = { };
    systemd.tmpfiles.rules = [
      "d ${cfg.textfileDirectory} 1775 root textfile -"
    ];

    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      listenAddress = cfg.listenAddress;
      enabledCollectors = cfg.enabledCollectors;
      extraFlags = [
        "--collector.textfile.directory=${cfg.textfileDirectory}"
        "--collector.systemd.enable-restarts-metrics"
      ];
    };
  };
}
