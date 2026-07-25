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
