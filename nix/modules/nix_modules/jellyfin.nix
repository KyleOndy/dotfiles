{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.jellyfin;
in
{
  options.systemFoundry.jellyfin = {
    enable = mkEnableOption ''
      Batteries included wrapper for jellyfin
    '';

    group = mkOption {
      type = types.str;
      # todo: can I pull the default from the jellyfin package?
      default = "jellyfin";
      description = "Group to run jellyfin under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server jellyfin under";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the jellyfin package?
      default = "jellyfin";
      description = "User to server jellyfin under";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # jellyfin service
      jellyfin = {
        enable = true;
        user = cfg.user;
        group = cfg.group;
        openFirewall = true;
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:8096";
    };
  };
}
