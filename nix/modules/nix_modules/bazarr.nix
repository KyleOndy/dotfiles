{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.bazarr;
in
{
  options.systemFoundry.bazarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for bazarr
    '';

    group = mkOption {
      type = types.str;
      # todo: can I pull the default from the bazarr package?
      default = "bazarr";
      description = "Group to run bazarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server bazarr under";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the bazarr package?
      default = "bazarr";
      description = "User to server bazarr under";
    };
    backup = mkOption {
      default = { };
      description = "Move the backups somewhere";
      type = types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable backup moving";
        };
        options.destinationPath = mkOption {
          type = types.path;
          default = "/var/backups/bazarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # bazarr service
      bazarr = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        user = cfg.user;
        group = cfg.group;
        openFirewall = true;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:6767";
    };
    systemd.services.bazarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn /var/lib/bazarr/backup ${cfg.backup.destinationPath}/
      '';
    };
  };
}
