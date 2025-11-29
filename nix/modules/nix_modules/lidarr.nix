{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.lidarr;
in
{
  options.systemFoundry.lidarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for Lidarr
    '';

    group = mkOption {
      type = types.str;
      default = "lidarr";
      description = "Group to run lidarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server lidarr under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "lidarr";
      description = "User to server lidarr under";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "media" ];
      description = "Additional groups for the lidarr user (e.g., for shared media access)";
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
          default = "/var/backups/lidarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # lidarr service
      lidarr = {
        # currently all config is done via the web.
        enable = true;
        package = pkgs.lidarr;
        user = cfg.user;
        group = cfg.group;
      };
    };

    # Add service user to extra groups for media access
    users.users.${cfg.user} = mkIf (cfg.extraGroups != [ ]) {
      extraGroups = cfg.extraGroups;
    };

    # Configure systemd service to use supplementary groups
    systemd.services.lidarr.serviceConfig = mkIf (cfg.extraGroups != [ ]) {
      SupplementaryGroups = cfg.extraGroups;
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:8686";
      provisionCert = cfg.provisionCert;
    };

    systemd.services.lidarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.lidarr.dataDir}/Backups ${cfg.backup.destinationPath}/
      '';
    };
  };
}
