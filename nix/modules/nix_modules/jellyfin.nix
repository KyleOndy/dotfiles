{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.jellyfin;
  stateDir = "/var/lib/jellyfin";
in
{
  options.systemFoundry.jellyfin = {
    enable = mkEnableOption ''
      Batteries included wrapper for jellyfin
    '';

    group = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "Group to run jellyfin under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server jellyfin under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    user = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "User to server jellyfin under";
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
          default = "/var/backups/jellyfin";
          description = "Specifies the directory backups will be moved too.";
        };
      };
    };

    transcodeCleanupInterval = mkOption {
      type = types.str;
      default = "6 hours";
      description = "How old transcode files must be before cleanup (e.g., '6 hours', '1 day', '30 minutes')";
      example = "12 hours";
    };
  };

  config = mkIf cfg.enable {
    services = {
      # jellyfin service
      jellyfin = {
        enable = true;
        package = pkgs.jellyfin;
        user = cfg.user;
        group = cfg.group;
        openFirewall = true;
      };
    };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:8096";
      provisionCert = cfg.provisionCert;
    };

    # Define rate limit zone for Jellyfin authentication endpoint
    services.nginx.commonHttpConfig = mkAfter ''
      # Rate limit zone for Jellyfin authentication (10 requests/minute per IP)
      limit_req_zone $binary_remote_addr zone=jellyfin_auth:10m rate=10r/m;
    '';

    # Add rate-limited location for auth endpoint
    services.nginx.virtualHosts."${cfg.domainName}".locations."/Users/AuthenticateByName" = {
      proxyPass = "http://127.0.0.1:8096";
      extraConfig = ''
        limit_req zone=jellyfin_auth burst=3 nodelay;
        limit_req_status 429;
      '';
    };

    systemd.services = {
      # jellyfin provides no native backup, so zip, compress it, and copy it over
      jellyfin-backup = mkIf cfg.backup.enable {
        startAt = "*-*-* 3:00:00";
        path = with pkgs; [
          coreutils
          gnutar
          pigz
        ];
        script = ''
          mkdir -p ${cfg.backup.destinationPath}
          tar --use-compress-program="pigz -k --best" -cvf ${cfg.backup.destinationPath}/jellyfin-$(date +%Y-%m-%d).tar.gz ${stateDir}

        '';
      };
      jellyfin-transcode-cleanup = {
        startAt = "*-*-* 04:00:00";
        path = with pkgs; [
          fd
        ];
        script = ''
          if [ -d "${stateDir}/transcodes" ]; then
            fd --type=file --changed-before="${cfg.transcodeCleanupInterval}" . ${stateDir}/transcodes/ -X rm -v --
          fi
        '';

      };
    };
  };
}
