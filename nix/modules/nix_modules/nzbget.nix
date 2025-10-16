{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.nzbget;

  # todo: don't know how to get this progamaticlly from the nzbget service,
  #       so hardcoding it here.
  stateDir = "/var/lib/nzbget";
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
          default = "/var/backups/nzbget";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      # nzbget service
      nzbget = {
        # currently all config is done via the web.
        # todo: setup some kind of autoamted downloading of backup zip
        enable = true;
        package = pkgs.nzbget;
        user = cfg.user;
        group = cfg.group;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:6789";
    };
    networking.firewall.allowedTCPPorts = [ 6789 ];
    systemd.services.nzbget-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${stateDir}/nzbget.conf ${cfg.backup.destinationPath}/nzbget-$(date +%Y-%m-%d).conf'';
    };
  };
}
