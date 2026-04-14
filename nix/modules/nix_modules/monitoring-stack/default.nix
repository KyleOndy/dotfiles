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
        Used only with the nginx reverse proxy (bearer token auth).
        Not used when caddyReverseProxy is enabled (use monitoringBasicAuth instead).
      '';
      example = {
        elk = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
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

  config = mkIf cfg.enable {
    # Add bearer token authentication map directives for nginx reverse proxy.
    # Only injected when nginx is being used (not Caddy).
    systemFoundry.nginxReverseProxy.appendHttpConfig =
      mkIf
        (
          (config.systemFoundry.nginxReverseProxy.enable)
          && (cfg.victoriametrics.enable || cfg.loki.enable)
          && cfg.tokenHashes != { }
        )
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
