{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.nixBuilders;
in
{
  options.systemFoundry.nixBuilders = {
    enable = mkEnableOption ''
      Distributed Nix build machines.

      Configures remote build machines for offloading package builds.
      Requires SSH access to be configured separately (e.g., via root SSH config).
    '';

    machines = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            hostName = mkOption {
              type = types.str;
              description = "SSH hostname or IP address of the builder";
              example = "builder.example.com";
            };

            sshUser = mkOption {
              type = types.str;
              default = "svc.deploy";
              description = "SSH user for connecting to the builder";
            };

            systems = mkOption {
              type = types.listOf types.str;
              default = [
                "x86_64-linux"
                "aarch64-linux"
              ];
              description = "List of system types the builder supports";
            };

            maxJobs = mkOption {
              type = types.int;
              default = 4;
              description = "Maximum number of concurrent jobs on this builder";
            };

            speedFactor = mkOption {
              type = types.int;
              default = 1;
              description = "Speed factor for prioritizing builders (higher = preferred)";
            };

            supportedFeatures = mkOption {
              type = types.listOf types.str;
              default = [
                "benchmark"
                "big-parallel"
              ];
              description = "List of supported Nix features on this builder";
            };

            sshPort = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "SSH port for the builder (if not default 22)";
            };
          };
        }
      );
      default = [ ];
      description = "List of remote build machines";
      example = [
        {
          hostName = "builder.example.com";
          sshUser = "svc.deploy";
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
          maxJobs = 8;
          speedFactor = 10;
        }
      ];
    };

    useSubstitutes = mkOption {
      type = types.bool;
      default = true;
      description = "Whether builders should use binary caches for their own dependencies";
    };
  };

  config = mkIf cfg.enable {
    nix.distributedBuilds = true;

    nix.buildMachines = map (
      machine:
      {
        hostName = machine.hostName;
        sshUser = machine.sshUser;
        systems = machine.systems;
        maxJobs = machine.maxJobs;
        speedFactor = machine.speedFactor;
        supportedFeatures = machine.supportedFeatures;
      }
      // optionalAttrs (machine.sshPort != null) { sshPort = machine.sshPort; }
    ) cfg.machines;

    nix.extraOptions = mkIf cfg.useSubstitutes ''
      builders-use-substitutes = true
    '';
  };
}
