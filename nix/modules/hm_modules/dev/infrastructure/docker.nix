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

  # Shared by the colima-start* aliases so a hand-started VM gets the same
  # sizing and, more importantly, the same mounts as the service. A manual
  # `colima start` without these silently restores colima's default $HOME
  # mount, which is the boundary `mounts = ["none"]` exists to hold.
  colimaCommonArgs =
    "--cpu ${toString cfg.service.cpu} --memory ${toString cfg.service.memory} --disk ${toString cfg.service.disk}"
    + concatMapStrings (m: " --mount ${m}") cfg.service.mounts;

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

    ${concatMapStringsSep "\n" (m: ''
      ARGS+=("--mount" "${m}")
    '') cfg.service.mounts}

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

    ${optionalString (cfg.service.sysctls != [ ]) ''
      # Apply kernel sysctl settings inside the VM
      echo "Applying kernel settings..."
      ${concatMapStringsSep "\n" (s: ''
        docker run --rm --privileged alpine sysctl -w "${s}" || true
      '') cfg.service.sysctls}
    ''}

    # Keep process alive for launchd
    echo "Colima started successfully, monitoring for shutdown signals..."
    tail -f /dev/null &
    wait $!
  '';
in
{
  options.hmFoundry.dev.docker = {
    enable = mkEnableOption "Docker and container tools";

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

      sysctls = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "fs.inotify.max_user_instances=1024" ];
        description = "Kernel sysctl settings to apply inside the Colima VM after startup.";
      };

      mounts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "none" ];
        description = ''
          Host directories mounted into the VM, one `--mount` argument each,
          `:w` suffix for writable. The single value `none` mounts nothing.
          Empty leaves colima's own default, which is $HOME writable.

          What is mounted here is the blast radius of the docker socket:
          any caller that reaches the daemon can start a privileged
          container and read or write every mounted path. `none` is what
          lets an agent sandbox grant the socket (pi's --allow-docker)
          without also surrendering ~/.ssh and ~/.aws.

          Changing this takes a `colima stop && colima start`; containers
          and their volumes survive it.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        docker_29
        docker-compose
        lazydocker
      ]
      ++ optionals pkgs.stdenv.isDarwin [
        pkgs.master.colima
        pkgs.master.lima
      ];

    home.sessionVariables = mkIf pkgs.stdenv.isDarwin {
      DOCKER_HOST = "unix://\${HOME}/.colima/default/docker.sock";
      # Fix testcontainers-go socket mount path for Colima
      TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = "/var/run/docker.sock";
    };

    programs.zsh.shellAliases = mkIf pkgs.stdenv.isDarwin {
      colima-start = "colima start ${colimaCommonArgs} --verbose=false 2>/dev/null";
      colima-start-rosetta = "colima start ${colimaCommonArgs} --vm-type vz --vz-rosetta --verbose=false 2>/dev/null";
      colima-start-k8s = "colima start ${colimaCommonArgs} --kubernetes --verbose=false 2>/dev/null";
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
