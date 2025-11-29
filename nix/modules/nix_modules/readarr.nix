{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.readarr;
in
{
  options.systemFoundry.readarr = {
    enable = mkEnableOption ''
      Batteries included wrapper for Readarr
    '';

    group = mkOption {
      type = types.str;
      default = "readarr";
      description = "Group to run readarr under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server readarr under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "readarr";
      description = "User to server readarr under";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "media" ];
      description = "Additional groups for the readarr user (e.g., for shared media access)";
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
          default = "/var/backups/readarr";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # readarr service
      readarr = {
        # currently all config is done via the web.
        enable = true;
        package = pkgs.readarr;
        user = cfg.user;
        group = cfg.group;
      };
    };

    # Add service user to extra groups for media access
    users.users.${cfg.user} = mkIf (cfg.extraGroups != [ ]) {
      extraGroups = cfg.extraGroups;
    };

    # Configure systemd service to use supplementary groups
    systemd.services.readarr.serviceConfig = mkIf (cfg.extraGroups != [ ]) {
      SupplementaryGroups = cfg.extraGroups;
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:8787";
      provisionCert = cfg.provisionCert;
    };

    systemd.services.readarr-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.readarr.dataDir}/Backups ${cfg.backup.destinationPath}/
      '';
    };
  };
}
