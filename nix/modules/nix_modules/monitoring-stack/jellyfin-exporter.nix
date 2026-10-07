{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.jellyfinExporter;

  # Package jellyfin_exporter from GitHub
  jellyfinExporterPkg = pkgs.buildGoModule rec {
    pname = "jellyfin_exporter";
    version = "1.3.9";

    src = pkgs.fetchFromGitHub {
      owner = "rebelcore";
      repo = "jellyfin_exporter";
      rev = "v${version}";
      hash = "sha256-oHPzdV+Fe7XmSyRWm5jh7oGqlY9uyLy7u9tCTlkfhQk=";
    };

    vendorHash = "sha256-Z3XM4vTsm5R/Me1jR9oqLcWqmEn1bd653UNvDKLM80g=";

    doCheck = false;

    ldflags = [
      "-s"
      "-w"
    ];

    meta = {
      description = "Prometheus exporter for Jellyfin media server";
      homepage = "https://github.com/rebelcore/jellyfin_exporter";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "jellyfin_exporter";
    };
  };
in
{
  options.systemFoundry.monitoringStack.jellyfinExporter = {
    enable = mkEnableOption "jellyfin_exporter for Jellyfin metrics";

    port = mkOption {
      type = types.port;
      default = 9594;
      description = "Port for jellyfin_exporter metrics endpoint";
    };

    jellyfinUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8096";
      description = "URL to Jellyfin server";
    };

    apiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Jellyfin API key";
    };

    enableActivityCollector = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Activity collector (requires Playback Reporting plugin)";
    };

    enabledCollectors = mkOption {
      type = types.listOf types.str;
      default = [
        "media"
        "playing"
        "system"
        "users"
      ];
      description = "List of collectors to enable";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.jellyfin-exporter = {
      description = "Jellyfin Prometheus Exporter";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "jellyfin.service"
      ];
      wants = [ "jellyfin.service" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        LoadCredential = "api-key:${cfg.apiKeyFile}";
        # The token has no file or env flag, so it goes in as a kingpin
        # @file argument rather than on the command line, where ps shows it:
        # https://github.com/alecthomas/kingpin/blob/v2.4.0/parser.go#L217-L227
        ExecStart = concatStringsSep " " (
          [
            (getExe jellyfinExporterPkg)
            "--web.listen-address=127.0.0.1:${toString cfg.port}"
            "--jellyfin.address=${cfg.jellyfinUrl}"
            "--jellyfin.token"
            "@%d/api-key"
          ]
          ++ map (c: "--collector.${c}") cfg.enabledCollectors
          ++ optional cfg.enableActivityCollector "--collector.activity"
        );
        Restart = "on-failure";
        RestartSec = "5s";
        Nice = 19;
        IOSchedulingClass = "idle";

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
      };
    };
  };
}
