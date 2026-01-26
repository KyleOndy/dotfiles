{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.tdarrExporter;
in
{
  options.systemFoundry.monitoringStack.tdarrExporter = {
    enable = mkEnableOption "Tdarr Prometheus exporter";

    port = mkOption {
      type = types.port;
      default = 9595;
      description = "Port for tdarr-exporter metrics endpoint";
    };

    tdarrUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8265";
      description = "Tdarr server URL";
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing Tdarr API key";
    };

    logLevel = mkOption {
      type = types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log level for the exporter";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Use systemd service instead of oci-containers to properly inject secrets
    systemd.services.tdarr-exporter = {
      description = "Tdarr Prometheus Exporter";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "podman.service"
      ];
      wants = [ "podman.service" ];

      path = [ pkgs.podman ];

      preStart = ''
        # Clean up any existing container
        ${pkgs.podman}/bin/podman rm -f tdarr-exporter 2>/dev/null || true
      '';

      serviceConfig =
        let
          startScript = pkgs.writeShellScript "tdarr-exporter-start" ''
            set -e
            ${optionalString (cfg.apiKeyFile != null) ''
              export TDARR_API_KEY=$(cat ${cfg.apiKeyFile})
            ''}

            exec ${pkgs.podman}/bin/podman run \
              --name=tdarr-exporter \
              --log-driver=journald \
              --rm \
              --network=host \
              -e TDARR_URL=${cfg.tdarrUrl} \
              ${optionalString (cfg.apiKeyFile != null) ''-e TDARR_API_KEY="$TDARR_API_KEY"''} \
              -e PROMETHEUS_PORT=${toString cfg.port} \
              -e LOG_LEVEL=${cfg.logLevel} \
              docker.io/homeylab/tdarr-exporter:latest
          '';
        in
        {
          Type = "simple";
          ExecStart = "${startScript}";
          Restart = "on-failure";
          RestartSec = "10s";
          TimeoutStopSec = "30s";
        };

      postStop = ''
        # Clean up container on stop
        ${pkgs.podman}/bin/podman rm -f tdarr-exporter 2>/dev/null || true
      '';
    };
  };
}
