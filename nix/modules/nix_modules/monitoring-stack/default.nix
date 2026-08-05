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
    ./arr-queue-janitor.nix
    ./jellyfin-exporter.nix
    ./unpoller.nix
  ];

  options.systemFoundry.monitoringStack = {
    enable = mkEnableOption "VictoriaMetrics-based monitoring stack";

    domain = mkOption {
      type = types.str;
      description = "Base domain for monitoring services";
      example = "apps.ondy.org";
    };

    # One mail account, used by both alertmanager (alert emails) and grafana
    # (its own notifications). It lives here rather than in either module so
    # neither has to reach into the other's option tree. The password is a
    # sops secret, read as monitoring_smtp_password at both use sites.
    #
    # MXRoute uses server-specific hostnames; keep this in step with
    # nix/modules/hm_modules/terminal/email.nix.
    smtp = {
      server = mkOption {
        type = types.str;
        default = "london.mxroute.com:587";
        description = "SMTP server address";
      };

      from = mkOption {
        type = types.str;
        default = "monitoring@ondy.org";
        description = "Email address to send alerts from";
      };

      to = mkOption {
        type = types.listOf types.str;
        default = [ "kyle@ondy.org" ];
        description = "Email addresses to send alerts to";
      };

      username = mkOption {
        type = types.str;
        default = "monitoring@ondy.org";
        description = "SMTP username for authentication";
      };
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
