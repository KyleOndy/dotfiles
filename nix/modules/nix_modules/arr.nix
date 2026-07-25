# The *arr services were five near-identical modules: same option set, same
# media-group plumbing, same Caddy site, same hourly backup copy. They are
# generated from one table here so a change to the shared shape happens once.
# Per-service quirks stay explicit in the table rather than becoming options.

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  arrs = {
    sonarr = {
      port = 8989;
      # sonarr drags in an end-of-life dotnet runtime.
      extraConfig.nixpkgs.config.allowInsecurePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "aspnetcore-runtime"
          "dotnet-sdk"
        ];
    };

    radarr.port = 7878;

    lidarr.port = 8686;

    bazarr = {
      port = 6767;
      # bazarr writes to a lowercase directory straight under dataDir, not the
      # Backups/ subdirectory the .NET *arrs use.
      backupSubdir = "backup";
      # Reached directly on the LAN as well as through Caddy.
      serviceArgs.openFirewall = true;
      # Left on the module default rather than pinned like the others.
      setPackage = false;
    };

    prowlarr = {
      port = 9696;
      # Upstream runs prowlarr under DynamicUser, so there is no static user to
      # put in the media group and the state directory may not exist yet.
      dynamicUser = true;
      backupScript = dest: ''
        if [ -d /var/lib/prowlarr/Backups ]; then
          cp -rn /var/lib/prowlarr/Backups/* ${dest}/ || true
        fi
      '';
    };
  };

  mkArr =
    name: spec:
    let
      cfg = config.systemFoundry.${name};
      dynamicUser = spec.dynamicUser or false;
      dest = cfg.backup.destinationPath;
    in
    {
      options.systemFoundry.${name} = {
        enable = mkEnableOption "Batteries included wrapper for ${name}";

        domainName = mkOption {
          type = types.str;
          description = "Domain to serve ${name} under";
        };
      }
      // optionalAttrs (!dynamicUser) {
        group = mkOption {
          type = types.str;
          default = name;
          description = "Group to run ${name} under";
        };
      }
      // {
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
              default = "/var/backups/${name}";
              description = "Specifies the directory backups will be moved to.";
            };
          };
        };
      };

      config = mkIf cfg.enable (mkMerge [
        {
          # All configuration beyond this is done through the web UI.
          services.${name} = {
            enable = true;
          }
          // optionalAttrs (spec.setPackage or true) { package = pkgs.${name}; }
          // optionalAttrs (!dynamicUser) {
            user = name;
            group = cfg.group;
          }
          // (spec.serviceArgs or { });

          systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
            mkIf config.systemFoundry.caddyReverseProxy.enable
              {
                enable = true;
                proxyPass = "http://127.0.0.1:${toString spec.port}";
              };

          systemd.services."${name}-backup" = mkIf cfg.backup.enable {
            startAt = "*-*-* *:00:00";
            path = [ pkgs.coreutils ];
            script = ''
              mkdir -p ${dest}
            ''
            + (
              if spec ? backupScript then
                spec.backupScript dest
              else
                "cp -rn ${config.services.${name}.dataDir}/${spec.backupSubdir or "Backups"} ${dest}/\n"
            );
          };
        }

        (mkIf (!dynamicUser) {
          # Create files 664 so the other *arr services and jellyfin can read
          # what this one writes. Group membership is the host's job: tiger
          # sets `group = mediaGroup`, which is already the process GID.
          systemd.services.${name}.serviceConfig.UMask = "0002";
        })

        (spec.extraConfig or { })
      ]);
    };
in
{
  imports = mapAttrsToList mkArr arrs;
}
