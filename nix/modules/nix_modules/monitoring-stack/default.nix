{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.monitoringStack;
in
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
    ./nginx_exporter.nix
    ./nginxlog_exporter.nix
    ./exportarr.nix
    ./jellyfin-exporter.nix
    ./jellyfin-playcount.nix
    ./tdarr-exporter.nix
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

    tokenHashes = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        SHA-256 hashes of bearer tokens for authenticating vmagent/promtail clients.
        Generate hashes with: echo -n "your-token" | sha256sum | cut -d' ' -f1
      '';
      example = {
        wolf = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        tiger = "d4735e3a265e16eee03f59718b9b5d03019c07d8b6c51f90da3a666eec13ab35";
        dino = "4e07408562bedb8b60ce05c1decfe3ad16b72230967de01f640b7e4729b49fce";
      };
    };
  };

  config = mkIf cfg.enable {
    # Add bearer token authentication map directives only when running server components
    # Token hashes are loaded from runtime-generated files created by systemd service
    # Only needed when VictoriaMetrics or Loki are enabled (server mode)
    systemFoundry.nginxReverseProxy.appendHttpConfig =
      mkIf (cfg.victoriametrics.enable || cfg.loki.enable)
        ''
          # Extract bearer token from Authorization header
          map $http_authorization $bearer_token {
            ~^Bearer\s+(\S+)$ $1;
            default "";
          }

          # Include runtime-generated token hash maps
          # These files are created by the monitoring-token-hash-generator systemd service
          # and contain the actual SHA-256 hashes of the bearer tokens
          include /run/monitoring-token-hashes/metrics-map.conf;
          include /run/monitoring-token-hashes/logs-map.conf;
        '';
  };
}
