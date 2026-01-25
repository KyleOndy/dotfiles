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

      serviceConfig =
        let
          collectorFlags =
            concatStringsSep " " (map (c: "--collector.${c}") cfg.enabledCollectors)
            + optionalString cfg.enableActivityCollector " --collector.activity";

          startScript = pkgs.writeShellScript "jellyfin-exporter-start" ''
            exec ${jellyfinExporterPkg}/bin/jellyfin_exporter \
              --web.listen-address=:${toString cfg.port} \
              --jellyfin.address=${cfg.jellyfinUrl} \
              --jellyfin.token="$(cat ${cfg.apiKeyFile})" \
              ${collectorFlags}
          '';
        in
        {
          Type = "simple";
          DynamicUser = true;
          ExecStart = "${startScript}";
          Restart = "on-failure";
          RestartSec = "5s";
        };
    };
  };
}
