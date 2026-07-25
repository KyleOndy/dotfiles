{ lib, ... }:
with lib;
{
  imports = [
    ./victoriametrics.nix
    ./loki.nix
    ./grafana.nix
    ./alertmanager.nix
    ./vmalert.nix
    ./vmagent.nix
    ./promtail.nix
    ./node_exporter.nix
    ./zfs_exporter.nix
    ./exportarr.nix
    ./jellyfin-exporter.nix
    ./jellyfin-playcount.nix
    ./unpoller.nix
  ];

  options.systemFoundry.monitoringStack = {
    enable = mkEnableOption "VictoriaMetrics-based monitoring stack";

    domain = mkOption {
      type = types.str;
      description = "Base domain for monitoring services";
      example = "apps.ondy.org";
    };

    retention = {
      metrics = mkOption {
        type = types.int;
        default = 90;
        description = "Days to retain metrics data";
      };

      logs = mkOption {
        type = types.int;
        default = 90;
        description = "Days to retain logs data";
      };
    };

    monitoringBasicAuth = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing 'username bcrypt-hash' lines for basic auth
        protecting the metrics write and log push endpoints via Caddy.
        Set to config.sops.secrets.<name>.path in the host config.
      '';
    };
  };
}
