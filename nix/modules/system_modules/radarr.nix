{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.radarr;
in
{
  options.systemFoundry.radarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for radarr
    '';

    group = mkOption {
      type = types.str;
      # todo: can I pull the default from the radarr package?
      default = "radarr";
      description = "Group to run radarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server radarr under";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the radarr package?
      default = "radarr";
      description = "User to server radarr under";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # radarr service
      radarr = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        user = cfg.user;
        group = cfg.group;
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:7878";
    };
  };
}
