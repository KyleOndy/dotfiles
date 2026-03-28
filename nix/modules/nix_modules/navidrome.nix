{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.navidrome;
in
{
  options.systemFoundry.navidrome = {
    enable = mkEnableOption ''
      Batteries included wrapper for Navidrome
    '';

    group = mkOption {
      type = types.str;
      default = "navidrome";
      description = "Group to run navidrome under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to serve navidrome under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "navidrome";
      description = "User to run navidrome under";
    };

    musicFolder = mkOption {
      type = types.str;
      default = "/mnt/storage/media/music";
      description = "Path to the music library";
    };

    port = mkOption {
      type = types.port;
      default = 4533;
      description = "Port for navidrome";
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
          default = "/var/backups/navidrome";
          description = "Specifies the directory backups will be moved to.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services.navidrome = {
      enable = true;
      user = cfg.user;
      group = cfg.group;
      settings = {
        MusicFolder = cfg.musicFolder;
        Address = "127.0.0.1";
        Port = cfg.port;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" =
      mkIf (config.systemFoundry.nginxReverseProxy.enable)
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          provisionCert = cfg.provisionCert;
        };

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          provisionCert = cfg.provisionCert;
        };

    systemd.services.navidrome-backup = mkIf cfg.backup.enable {
      startAt = "*-*-* *:00:00";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${cfg.backup.destinationPath}
        cp -rn /var/lib/navidrome ${cfg.backup.destinationPath}/
      '';
    };
  };
}
