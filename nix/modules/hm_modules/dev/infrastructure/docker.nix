# Docker and container tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.docker;

  # Wrapper script with proper signal handling for Colima service
  colimaWrapper = pkgs.writeShellScript "colima-wrapper" ''
    set -euo pipefail

    COLIMA_BIN="${pkgs.master.colima}/bin/colima"

    shutdown() {
      echo "Received shutdown signal, stopping colima..."
      $COLIMA_BIN stop
      exit 0
    }

    trap shutdown SIGTERM SIGINT

    # Build colima start arguments
    ARGS=(
      "--cpu" "${toString cfg.service.cpu}"
      "--memory" "${toString cfg.service.memory}"
      "--disk" "${toString cfg.service.disk}"
    )

    ${optionalString (cfg.service.vmType != null) ''
      ARGS+=("--vm-type" "${cfg.service.vmType}")
    ''}

    ${optionalString cfg.service.rosetta ''
      ARGS+=("--vz-rosetta")
    ''}

    ${optionalString cfg.service.kubernetes.enable ''
      ARGS+=("--kubernetes")
      ${optionalString (cfg.service.kubernetes.version != null) ''
        ARGS+=("--kubernetes-version" "${cfg.service.kubernetes.version}")
      ''}
    ''}

    ${optionalString (cfg.service.extraArgs != [ ]) ''
      ARGS+=(${concatMapStringsSep " " (arg: ''"${arg}"'') cfg.service.extraArgs})
    ''}

    # Start colima if not already running
    echo "Starting colima with arguments: ''${ARGS[@]}"
    while true; do
      if $COLIMA_BIN status &>/dev/null; then
        echo "Colima is running"
        break
      fi
      echo "Starting colima..."
      $COLIMA_BIN start "''${ARGS[@]}" || true
      sleep 5
    done

    # Keep process alive for launchd
    echo "Colima started successfully, monitoring for shutdown signals..."
    tail -f /dev/null &
    wait $!
  '';
in
{
  options.hmFoundry.dev.docker = {
    enable = mkEnableOption "Docker and container tools";

    enableLazydocker = mkOption {
      type = types.bool;
      default = true;
      description = "Include lazydocker TUI for container management";
    };

    service = {
      enable = mkEnableOption "Colima background service (macOS only)";

      cpu = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Number of CPU cores to allocate to Colima VM";
      };

      memory = mkOption {
        type = types.ints.positive;
        default = 8;
        description = "Amount of RAM in GB to allocate to Colima VM";
      };

      disk = mkOption {
        type = types.ints.positive;
        default = 100;
        description = "Amount of disk space in GB to allocate to Colima VM";
      };

      vmType = mkOption {
        type = types.nullOr (
          types.enum [
            "qemu"
            "vz"
          ]
        );
        default = null;
        description = ''
          VM type to use. Options:
          - qemu: QEMU-based virtualization (default, compatible)
          - vz: macOS Virtualization.framework (faster, requires macOS 13+)
        '';
      };

      rosetta = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable Rosetta for x86_64 emulation on ARM Macs.
          Only works with vmType = "vz" on Apple Silicon.
        '';
      };

      kubernetes = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Kubernetes cluster in Colima";
        };

        version = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "v1.28.3+k3s2";
          description = "Kubernetes version to install (defaults to latest stable)";
        };
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "--network-address"
          "--dns"
          "1.1.1.1"
        ];
        description = "Additional arguments to pass to colima start";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        docker
        docker-compose
      ]
      ++ optionals pkgs.stdenv.isDarwin [
        pkgs.master.colima
        pkgs.master.lima
      ]
      ++ optionals cfg.enableLazydocker [
        lazydocker
      ];

    home.sessionVariables = mkIf pkgs.stdenv.isDarwin {
      DOCKER_HOST = "unix://\${HOME}/.colima/default/docker.sock";
      # Fix testcontainers-go socket mount path for Colima
      TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = "/var/run/docker.sock";
    };

    programs.zsh.shellAliases = mkIf pkgs.stdenv.isDarwin {
      colima-start = "colima start --cpu 4 --memory 8 --disk 100 --verbose=false 2>/dev/null";
      colima-start-rosetta = "colima start --cpu 4 --memory 8 --disk 100 --vm-type vz --vz-rosetta --verbose=false 2>/dev/null";
      colima-start-k8s = "colima start --cpu 4 --memory 8 --disk 100 --kubernetes --verbose=false 2>/dev/null";
    };

    # Colima launchd service (macOS only)
    launchd.agents.colima = mkIf (pkgs.stdenv.isDarwin && cfg.service.enable) {
      enable = true;
      config = {
        Label = "com.github.abiosoft.colima";
        ProgramArguments = [ "${colimaWrapper}" ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardOutPath = "${config.home.homeDirectory}/.colima/service.stdout.log";
        StandardErrorPath = "${config.home.homeDirectory}/.colima/service.stderr.log";
        ProcessType = "Background";
        EnvironmentVariables = {
          PATH = "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        };
      };
    };
  };
}
