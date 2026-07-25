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
        # currently all config is done via the web.
        enable = true;
        package = pkgs.sabnzbd;
        group = cfg.group;
      };
    };

    # Files land 664 so the *arr services can import what sabnzbd downloads.
    # Group membership is the host's job: tiger sets `group = mediaGroup`,
    # which is already the process GID.
    systemd.services.sabnzbd.serviceConfig.UMask = "0002";

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:8080";
        };
  };
}
