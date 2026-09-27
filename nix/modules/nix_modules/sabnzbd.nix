{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.sabnzbd;
in
{
  options.systemFoundry.sabnzbd = {
    enable = mkEnableOption ''
      Batteries included wrapper for SABnzbd
    '';

    group = mkOption {
      type = types.str;
      default = "sabnzbd";
      description = "Group to run sabnzbd under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server sabnzbd under";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # sabnzbd service
      sabnzbd = {
        enable = true;
        package = pkgs.sabnzbd;
        group = cfg.group;
        # sabnzbd.ini stays writable so the web UI owns every key nix does not
        # set. The keys nix does set, the module's own defaults included, are
        # merged back over the ini on each start, which reverts a web UI edit
        # to one of them at the next restart.
        configFile = null;
        allowConfigWrite = true;
        # SABnzbd reruns every conversion above the stored version on start,
        # and 5 resets each server's pipelining_requests to 1. nixpkgs defaults
        # this to 4, which would undo a pipelining change at every restart.
        # Glitter re-shows its new-skin notice while notified_new_skin < 2,
        # and nixpkgs' default renders as 1.
        settings.misc = {
          config_conversion_version = 5;
          notified_new_skin = 2;
        };
      };
    };

    # Files land 664 so the *arr services can import what sabnzbd downloads.
    # Group membership is the host's job: tiger sets `group = mediaGroup`,
    # which is already the process GID.
    systemd.services.sabnzbd.serviceConfig.UMask = "0002";

    # A sabnzbd bump that adds a conversion would otherwise rerun it on every
    # start, silently.
    system.checks = [
      (pkgs.runCommand "sabnzbd-conversion-version" { } ''
        latest=$(sed -n 's/.*config_conversion_version() < \([0-9]*\):.*/\1/p' \
          ${config.services.sabnzbd.package}/sabnzbd/cfg.py | sort -n | tail -1)
        if [ "$latest" != ${toString config.services.sabnzbd.settings.misc.config_conversion_version} ]; then
          echo "sabnzbd ships config conversion $latest; bump config_conversion_version" >&2
          exit 1
        fi
        touch $out
      '')
    ];

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:8080";
        };
  };
}
