{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.prowlarr;
in
{
  options.systemFoundry.prowlarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for Prowlarr
    '';

    group = mkOption {
      type = types.str;
      default = "prowlarr";
      description = "Group to run prowlarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server prowlarr under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "prowlarr";
      description = "User to server prowlarr under";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "media" ];
      description = "Additional groups for the prowlarr user (e.g., for shared media access)";
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
          default = "/var/backups/prowlarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # prowlarr service
      prowlarr = {
        # currently all config is done via the web.
        enable = true;
        package = pkgs.prowlarr;
        user = cfg.user;
        group = cfg.group;
      };
    };

    # Add service user to extra groups for media access
    users.users.${cfg.user} = mkIf (cfg.extraGroups != [ ]) {
      extraGroups = cfg.extraGroups;
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:9696";
      provisionCert = cfg.provisionCert;
    };

    systemd.services.prowlarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.prowlarr.dataDir}/Backups ${cfg.backup.destinationPath}/
      '';
    };
  };
}
