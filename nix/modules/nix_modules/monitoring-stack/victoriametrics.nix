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

    domain = mkOption {
      type = types.str;
      default = "metrics.${parentCfg.domain}";
      description = "Domain name for VictoriaMetrics (defaults to metrics.{parent domain})";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for VictoriaMetrics domain";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.victoriametrics = {
      enable = true;
      listenAddress = "${cfg.listenAddress}:${toString cfg.port}";
      retentionPeriod = "${toString cfg.retentionPeriod}d";
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domain}" = {
      enable = true;
      proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
      provisionCert = cfg.provisionCert;
      route53HostedZoneId = "Z0365859SHHFAPNR0QXN"; # ondy.org zone
      extraConfig = mkIf (parentCfg.tokenHashes != { }) ''
        # Require valid bearer token for write endpoints
        if ($request_uri ~ "^/api/v1/(write|import)") {
          set $auth_check "$valid_metrics_token";
        }
        if ($auth_check = "") {
          return 401 "Unauthorized: Invalid or missing bearer token\n";
        }
      '';
    };
  };
}
