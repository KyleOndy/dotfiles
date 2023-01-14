{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.gitea;
in
{
  # todo: submodules?
  options.systemFoundry.gitea = {
    enable = mkEnableOption ''
      Batteries included wrapper for gitea
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain to server gitea under";
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
          default = "/var/backups/gitea";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services = {
      gitea = {
        enable = true;
        appName = "git.ondy.org";
        #cookieSecure = true;
        cookieSecure = false;
        disableRegistration = true;
        domain = "${cfg.domainName}";
        rootUrl = "https://${cfg.domainName}/";
        dump = mkIf cfg.backup.enable {
          enable = true;
          type = "tar.gz";
          interval = "hourly";
        };
      };
    };

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      #proxyPass = "http://${config.services.gitea.httpAddress}:${toString config.services.gitea.httpPort}";
      proxyPass = "http://127.0.0.1:3000";
    };
    networking.firewall.allowedTCPPorts = [ 3000 ];
    systemd.services.gitea-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn ${config.services.gitea.stateDir}/dump/ ${cfg.backup.destinationPath}/
      '';
    };
  };
}
