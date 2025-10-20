{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.radarr;
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

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      # todo: can I pull the default from the radarr package?
      default = "radarr";
      description = "User to server radarr under";
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
          default = "/var/backups/radarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # radarr service
      radarr = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        package = pkgs.radarr;
        enable = true;
        user = cfg.user;
        group = cfg.group;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:7878";
      provisionCert = cfg.provisionCert;
    };
    systemd.services.radarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.radarr.dataDir}/Backups ${cfg.backup.destinationPath}/
      '';
    };
  };
}
