# Base configuration that all profiles should include
# Contains the absolute minimum requirements for any system

{
  pkgs,
  config,
  lib,
  ...
}:
with lib;
{
  # Feature flags that can be used by modules to conditionally enable functionality
  options.hmFoundry.features = {
    isDevelopment = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this profile includes development tools";
    };
    isDesktop = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this profile includes desktop/GUI applications";
    };
    isServer = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this profile is for server deployments";
    };
    isGaming = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this profile includes gaming support";
    };

    # Package feature flags for conditional loading
    isKubernetes = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Kubernetes development tools";
    };
    isAWS = mkOption {
      type = types.bool;
      default = false;
      description = "Enable AWS CLI and related tools";
    };
    isTerraform = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Terraform and infrastructure tools";
    };
    isDocker = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Docker and container tools";
    };
    isMediaDev = mkOption {
      type = types.bool;
      default = false;
      description = "Enable media processing and content creation tools";
    };
    isDocuments = mkOption {
      type = types.bool;
      default = false;
      description = "Enable document processing and writing tools";
    };
    isSystemAdmin = mkOption {
      type = types.bool;
      default = false;
      description = "Enable system administration and monitoring tools";
    };
    isMonitoring = mkOption {
      type = types.bool;
      default = false;
      description = "Enable advanced monitoring and diagnostic tools";
    };
    isSecurity = mkOption {
      type = types.bool;
      default = false;
      description = "Enable security and secrets management tools";
    };
    isPerformance = mkOption {
      type = types.bool;
      default = false;
      description = "Enable performance analysis and optimization tools";
    };
    isNixDev = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Nix development and packaging tools";
    };
    isClojureDev = mkOption {
      type = types.bool;
      default = false;
      description = "Enable additional Clojure development tools";
    };
  };

  config = {
    # Essential programs every profile needs
    programs = {
      home-manager.enable = true;
      lesspipe.enable = true;
    };

    # Essential services
    services = {
      lorri.enable = true;
    };

    # Base environment setup
    home = {
      stateVersion = "18.09";

      # Only the most essential packages that every system needs
      packages = with pkgs; [
        coreutils-full
        findutils
        gnused
        gnumake
        man-pages
      ];
    };
  };
}
