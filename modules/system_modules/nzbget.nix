{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.nzbget;
in
{
  # todo: submodules?
  options.systemFoundry.nzbget = {
    enable = mkEnableOption ''
      Batteries included wrapper for nzbget
    '';

    group = mkOption {
      type = types.str;
      # todo: can I pull the default from the nzbget package?
      default = "nzbget";
      description = "Group to run nzbget under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server nzbget under";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the nzbget package?
      default = "nzbget";
      description = "User to server nzbget under";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # nzbget service
      nzbget = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        user = cfg.user;
        group = cfg.group;
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:6789";
    };
  };
}
