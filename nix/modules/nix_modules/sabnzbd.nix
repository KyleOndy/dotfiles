{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.sabnzbd;
  stateDir = "/var/lib/sabnzbd";
in
{
  options.systemFoundry.sabnzbd = {
    enable = mkEnableOption ''
      Batteries included wrapper for SABnzbd
    '';

    group = mkOption {
      type = types.str;
      default = "sabnzbd";
      description = "Group to run sabnzbd under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server sabnzbd under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "sabnzbd";
      description = "User to server sabnzbd under";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "media" ];
      description = "Additional groups for the sabnzbd user (e.g., for shared media access)";
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
          default = "/var/backups/sabnzbd";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # sabnzbd service
      sabnzbd = {
        # currently all config is done via the web.
        enable = true;
        package = pkgs.sabnzbd;
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
      proxyPass = "http://127.0.0.1:8080";
      provisionCert = cfg.provisionCert;
    };

    systemd.services.sabnzbd-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${stateDir}/admin/sabnzbd.ini ${cfg.backup.destinationPath}/sabnzbd-$(date +%Y-%m-%d).ini
      '';
    };
  };
}
