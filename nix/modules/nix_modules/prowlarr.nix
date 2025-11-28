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
        # NOTE: The upstream prowlarr module does not support custom user/group options.
        # It uses DynamicUser = true for better security isolation.
        # Unlike other *arr services (sonarr, radarr, etc.), prowlarr in NixOS 25.05
        # does not expose user/group configuration options.
      };
    };

    # NOTE: Cannot configure users.users for dynamic user created by prowlarr service.
    # The user/group/extraGroups options defined above are kept for API compatibility
    # but are not actually used. If media access is needed, consider:
    # 1. Setting appropriate ACLs on media directories
    # 2. Using bind mounts with different permissions
    # 3. Configuring prowlarr to only index (not access files directly)

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
        # Note: prowlarr uses DynamicUser, so dataDir is /var/lib/prowlarr
        # The service itself sees /var/lib/private/prowlarr due to systemd's PrivateUsers
        # but we can access it via /var/lib/prowlarr with appropriate permissions
        if [ -d /var/lib/prowlarr/Backups ]; then
          cp -rn /var/lib/prowlarr/Backups/* ${cfg.backup.destinationPath}/ || true
        fi
      '';
    };
  };
}
