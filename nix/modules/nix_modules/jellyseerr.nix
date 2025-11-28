{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.jellyseerr;
in
{
  options.systemFoundry.jellyseerr = {
    enable = mkEnableOption ''
      Batteries included wrapper for Jellyseerr
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain to server jellyseerr under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # jellyseerr service
      jellyseerr = {
        # currently all config is done via the web.
        enable = true;
        package = pkgs.jellyseerr;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:5055";
      provisionCert = cfg.provisionCert;
    };
  };
}
