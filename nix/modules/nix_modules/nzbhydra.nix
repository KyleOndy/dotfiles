{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.nzbhydra2;
in
{
  options.systemFoundry.nzbhydra2 = {
    enable = mkEnableOption ''
      Batteries included wrapper for nzbhydra2
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain to server nzbhydra2 under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
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
      # nzbhydra2 service
      nzbhydra2 = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        package = pkgs.nzbhydra2;
        openFirewall = true;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:5076";
      provisionCert = cfg.provisionCert;
    };
    systemd.services.nzbhydra2-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.nzbhydra2.dataDir}/backup/ ${cfg.backup.destinationPath}/
      '';
    };
  };
}
