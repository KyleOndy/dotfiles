{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.sonarr;
in
{
  # todo: submodules?
  options.systemFoundry.sonarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for Sonarr
    '';

    group = mkOption {
      type = types.str;
      # todo: can I pull the default from the sonarr package?
      default = "sonarr";
      description = "Group to run sonarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server sonarr under";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the sonarr package?
      default = "sonarr";
      description = "User to server sonarr under";
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
          default = "/var/backups/sonarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # sonarr service
      sonarr = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        user = cfg.user;
        group = cfg.group;
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:8989";
    };

    systemd.services.sonarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.sonarr.dataDir}/Backups ${cfg.backup.destinationPath}/
      '';
    };

  };
}
