{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.exportarr;

  # Helper function to create systemd service for each *arr app
  mkExportarrService =
    app: appCfg:
    nameValuePair "exportarr-${app}" {
      description = "Exportarr Prometheus exporter for ${app}";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "${app}.service"
      ];
      wants = [ "${app}.service" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        # systemd copies the root-only key in for this unit alone, so no
        # exporter can read another app's key.
        LoadCredential = "api-key:${appCfg.apiKeyFile}";
        ExecStart = ''
          ${pkgs.exportarr}/bin/exportarr ${app} \
            --interface 127.0.0.1 \
            --port ${toString appCfg.port} \
            --log-level warn \
            --url ${appCfg.url} \
            --api-key-file %d/api-key \
            ${
              optionalString (app != "sabnzbd" && appCfg.enableAdditionalMetrics) "--enable-additional-metrics"
            } \
            ${optionalString (
              app != "sabnzbd" && appCfg.enableUnknownQueueItems
            ) "--enable-unknown-queue-items"}
        '';
        Restart = "on-failure";
        RestartSec = "5s";

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # The app and the scraper are both on this host.
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

  # Helper to create per-service options
  mkServiceOptions = defaultPort: servicePort: {
    enable = mkEnableOption "exportarr exporter for this service";

    port = mkOption {
      type = types.port;
      default = defaultPort;
      description = "Port for exportarr metrics endpoint";
    };

    url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString servicePort}";
      description = "URL to the service";
    };

    apiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing API key for the service";
    };

    enableAdditionalMetrics = mkOption {
      type = types.bool;
      default = true;
      description = "Enable additional metrics collection";
    };

    enableUnknownQueueItems = mkOption {
      type = types.bool;
      default = true;
      description = "Enable collection of unknown queue items";
    };
  };
in
{
  options.systemFoundry.monitoringStack.exportarr = {
    enable = mkEnableOption "exportarr Prometheus exporters for *arr services";

    # Per-service configuration
    sonarr = mkServiceOptions 9707 8989;
    radarr = mkServiceOptions 9708 7878;
    lidarr = mkServiceOptions 9709 8686;
    prowlarr = mkServiceOptions 9711 9696;
    bazarr = mkServiceOptions 9712 6767;
    sabnzbd = mkServiceOptions 9713 8080;
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services = listToAttrs (
      optional (cfg.sonarr.enable) (mkExportarrService "sonarr" cfg.sonarr)
      ++ optional (cfg.radarr.enable) (mkExportarrService "radarr" cfg.radarr)
      ++ optional (cfg.lidarr.enable) (mkExportarrService "lidarr" cfg.lidarr)
      ++ optional (cfg.prowlarr.enable) (mkExportarrService "prowlarr" cfg.prowlarr)
      ++ optional (cfg.bazarr.enable) (mkExportarrService "bazarr" cfg.bazarr)
      ++ optional (cfg.sabnzbd.enable) (mkExportarrService "sabnzbd" cfg.sabnzbd)
    );
  };
}
