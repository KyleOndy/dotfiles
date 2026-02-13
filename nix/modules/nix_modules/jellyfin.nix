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

    debugAuthLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug-level logging for authentication (helps diagnose invalid token issues)";
    };

    transcodeDebugLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug-level logging for transcoding operations";
    };

    installPlaybackReportingPlugin = mkOption {
      type = types.bool;
      default = false;
      description = "Automatically install the Playback Reporting plugin for play history tracking";
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

      # nginx reverse proxy with WebSocket support
      nginx = {
        enable = true;
        virtualHosts."${cfg.domainName}" = {
          enableACME = cfg.provisionCert;
          forceSSL = cfg.provisionCert;

          locations."/" = {
            proxyPass = "http://127.0.0.1:8096";
            proxyWebsockets = true;
            extraConfig = ''
              # required when the target is also TLS server with multiple hosts
              proxy_ssl_server_name on;
              # required when the server wants to use HTTP Authentication
              proxy_pass_header Authorization;

              # Increase timeouts for large media files and slow transcodes
              # Blu-ray ISOs over NFS can take 60+ seconds to probe
              proxy_read_timeout 300s;
              proxy_send_timeout 300s;
              proxy_buffering off;
            '';
          };

          locations."/Users/AuthenticateByName" = {
            proxyPass = "http://127.0.0.1:8096";
            extraConfig = ''
              limit_req zone=jellyfin_auth burst=3 nodelay;
              limit_req_status 429;
            '';
          };

          extraConfig = ''
            # Use prometheus log format for metrics collection
            access_log /var/log/nginx/access.log prometheus;
            error_log /var/log/nginx/${cfg.domainName}.error error;
          '';
        };
      };
    };

    # Define rate limit zone for Jellyfin authentication endpoint
    services.nginx.commonHttpConfig = mkAfter ''
      # Rate limit zone for Jellyfin authentication (10 requests/minute per IP)
      limit_req_zone $binary_remote_addr zone=jellyfin_auth:10m rate=10r/m;
    '';

    # ACME certificate configuration (when provisionCert is enabled)
    security.acme = mkIf cfg.provisionCert {
      acceptTerms = true;
      defaults.email = config.systemFoundry.nginxReverseProxy.acme.email;
      certs."${cfg.domainName}" = {
        dnsProvider = config.systemFoundry.nginxReverseProxy.acme.dnsProvider;
        environmentFile =
          config.sops.secrets.${config.systemFoundry.nginxReverseProxy.acme.credentialsSecret}.path;
        webroot = null;
      };
    };

    # Allow nginx to read ACME certificates
    users.users.nginx.extraGroups = mkIf cfg.provisionCert [ "acme" ];

    # Open firewall for HTTPS (HTTP already opened by nginxReverseProxy if used elsewhere)
    networking.firewall.allowedTCPPorts = mkIf cfg.provisionCert [
      80
      443
    ];

    # Configure debug logging when enabled
    systemd.tmpfiles.rules = mkIf (cfg.debugAuthLogging || cfg.transcodeDebugLogging) [
      "f+ ${stateDir}/config/logging.json 0640 ${cfg.user} ${cfg.group} - ${
        pkgs.writeText "jellyfin-logging.json" (
          builtins.toJSON {
            Serilog = {
              MinimumLevel = {
                Default = "Information";
                Override = {
                  Microsoft = "Warning";
                  System = "Warning";
                }
                // optionalAttrs cfg.debugAuthLogging {
                  "Jellyfin.Api.Auth" = "Debug";
                  "Microsoft.AspNetCore.Authentication" = "Debug";
                }
                // optionalAttrs cfg.transcodeDebugLogging {
                  "MediaBrowser.MediaEncoding.Transcoding" = "Debug";
                  "MediaBrowser.Controller.MediaEncoding" = "Debug";
                };
              };
              WriteTo = [
                {
                  Name = "Console";
                  Args = {
                    outputTemplate = "[{Timestamp:HH:mm:ss}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message:lj}{NewLine}{Exception}";
                  };
                }
                {
                  Name = "Async";
                  Args = {
                    configure = [
                      {
                        Name = "File";
                        Args = {
                          path = "%JELLYFIN_LOG_DIR%//log_.log";
                          rollingInterval = "Day";
                          retainedFileCountLimit = 3;
                          rollOnFileSizeLimit = true;
                          fileSizeLimitBytes = 100000000;
                          outputTemplate = "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message}{NewLine}{Exception}";
                        };
                      }
                    ];
                  };
                }
              ];
              Enrich = [
                "FromLogContext"
                "WithThreadId"
              ];
            };
          }
        )
      }"
    ];

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

    # Install Playback Reporting plugin if enabled
    systemd.services.jellyfin-install-playback-reporting = mkIf cfg.installPlaybackReportingPlugin {
      description = "Install Jellyfin Playback Reporting Plugin";
      wantedBy = [ "jellyfin.service" ];
      before = [ "jellyfin.service" ];
      path = with pkgs; [
        unzip
        curl
        coreutils
      ];
      script =
        let
          pluginDir = "${stateDir}/plugins/Jellyfin.Plugin.PlaybackReporting";
          # Using version 15.0.0.0 which is compatible with Jellyfin 10.8+
          pluginUrl = "https://github.com/jellyfin/jellyfin-plugin-playbackreporting/releases/download/15.0.0.0/playback_reporting_15.0.0.0.zip";
        in
        ''
          # Create plugins directory if it doesn't exist
          mkdir -p ${stateDir}/plugins

          # Only install if not already present
          if [ ! -d "${pluginDir}" ]; then
            echo "Installing Playback Reporting plugin..."

            # Download plugin
            curl -L -o /tmp/playback_reporting.zip "${pluginUrl}"

            # Create plugin directory
            mkdir -p "${pluginDir}"

            # Extract plugin
            unzip -o /tmp/playback_reporting.zip -d "${pluginDir}"

            # Clean up
            rm /tmp/playback_reporting.zip

            # Set ownership
            chown -R ${cfg.user}:${cfg.group} "${pluginDir}"

            echo "Playback Reporting plugin installed successfully"
          else
            echo "Playback Reporting plugin already installed"
          fi
        '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root"; # Need root to chown
      };
    };
  };
}
