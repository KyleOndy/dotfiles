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
        cheetah = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        tiger = "d4735e3a265e16eee03f59718b9b5d03019c07d8b6c51f90da3a666eec13ab35";
        dino = "4e07408562bedb8b60ce05c1decfe3ad16b72230967de01f640b7e4729b49fce";
      };
    };
  };

  config = mkIf cfg.enable {
    # Add bearer token authentication map directives
    systemFoundry.nginxReverseProxy.appendHttpConfig = mkIf (cfg.tokenHashes != { }) ''
      # Extract bearer token from Authorization header
      map $http_authorization $bearer_token {
        ~^Bearer\s+(\S+)$ $1;
        default "";
      }

      # Validate token hash for VictoriaMetrics ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map $bearer_token $valid_metrics_token {
        ${lib.concatStringsSep "\n    " (
          lib.mapAttrsToList (host: hash: ''"${hash}" "1";'') cfg.tokenHashes
        )}
        default "";
      }

      # Validate token hash for Loki ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map $bearer_token $valid_logs_token {
        ${lib.concatStringsSep "\n    " (
          lib.mapAttrsToList (host: hash: ''"${hash}" "1";'') cfg.tokenHashes
        )}
        default "";
      }
    '';
  };
}
