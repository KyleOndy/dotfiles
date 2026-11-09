{
  lib,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.unpoller;
in
{
  options.systemFoundry.monitoringStack.unpoller = {
    enable = mkEnableOption "unpoller for UniFi controller metrics";

    port = mkOption {
      type = types.port;
      default = 9130;
      description = "Port for the unpoller Prometheus endpoint";
    };

    controllerUrl = mkOption {
      type = types.str;
      description = ''
        URL of the UniFi controller. UniFi OS consoles (UDM/UDM Pro/UDM SE)
        serve the controller on 443, not the 8443 used by the standalone
        Network application.
      '';
      example = "https://10.24.89.1";
    };

    user = mkOption {
      type = types.str;
      default = "unpoller";
      description = ''
        UniFi admin used to poll the controller. Must be a local-only account
        with the Read Only role; cloud SSO accounts cannot authenticate here.
      '';
    };

    passwordFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the UniFi user's password. Must be readable
        by the unifi-poller user created by the upstream module.
      '';
    };

    verifySsl = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Verify the controller's TLS certificate. Off by default: UniFi OS
        consoles ship a self-signed cert for their LAN address.
      '';
    };

    saveDpi = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Collect deep packet inspection stats. Adds roughly 150 series per
        client and noticeably increases the polling cost on the gateway.
      '';
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Every poll fetches the site's device tags, and below Network 11.0.96
    # each fetch leaks an HTTP/2 stream in the UDM's Network app, about 11 MB
    # of heap a day until it stalls
    # (https://github.com/timgladwell/homelab/issues/388). Network 11 needs
    # UniFi OS 6, which the UDM Pro is not offered yet. unpoller 5.9.3 can
    # skip the fetch; nixpkgs ships 2.39.0.
    nixpkgs.overlays = [
      (final: prev: {
        unpoller =
          if lib.versionOlder prev.unpoller.version "5.9.3" then
            prev.unpoller.overrideAttrs (old: {
              version = "5.9.4";
              src = old.src.override {
                hash = "sha256-LOAdTGFEx4W2Bqi8u0jwDkljKI0qb353regSD3gEWwM=";
              };
              vendorHash = "sha256-1dqXfHU0kZ/LizR55Q629Xk6YfyFLTeu91oXoqogOBI=";
            })
          else
            prev.unpoller;
      })
    ];
    systemd.services.unifi-poller.environment = {
      UP_UNIFI_DEFAULT_SKIP_DEVICE_TAGS = "true";
      # From 3.2.0 /metrics serves a background poll and keeps the last good
      # one when the controller fails, so an outage reads as frozen values
      # with up at 1. 0 polls on each scrape, so it shows as a gap.
      UP_PROMETHEUS_INTERVAL = "0";
    };

    services.unpoller = {
      enable = true;

      # Only startup and error logs. The default emits a line per poll
      # interval, which is pure noise once this is working.
      poller.quiet = true;

      prometheus = {
        # Bound to loopback: vmagent scrapes locally, nothing else needs it.
        http_listen = "127.0.0.1:${toString cfg.port}";
        disable = false;
      };

      # Prometheus is the only output. Left enabled, the influxdb plugin
      # retries against 127.0.0.1:8086 forever and fills the journal.
      influxdb.disable = true;

      unifi.defaults = {
        url = cfg.controllerUrl;
        inherit (cfg) user;
        pass = cfg.passwordFile;
        verify_ssl = cfg.verifySsl;
        save_dpi = cfg.saveDpi;
        save_sites = true;
        sites = "all";
      };
    };
  };
}
