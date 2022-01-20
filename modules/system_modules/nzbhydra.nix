{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.nzbhydra2;
in
{
  options.systemFoundry.nzbhydra2 = {
    enable = mkEnableOption ''
      Batteries included wrapper for nzbhydra2
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain to server nzbhydra2 under";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # nzbhydra2 service
      nzbhydra2 = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:5076";
    };
  };
}
