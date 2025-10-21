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
    # Ensure textfile directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.textfileDirectory} 0755 root root -"
    ];

    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      listenAddress = cfg.listenAddress;
      enabledCollectors = cfg.enabledCollectors;
      extraFlags = [ "--collector.textfile.directory=${cfg.textfileDirectory}" ];
    };
  };
}
