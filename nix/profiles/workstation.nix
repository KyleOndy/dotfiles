# Workstation profile - full development environment with desktop
# This profile is a complete development setup with GUI applications

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/desktop.nix
    ./common/ssh-hosts.nix
  ];

  hmFoundry.features = {
    isDevelopment = true;
    isDesktop = true;
    isServer = false;
    isGaming = false;

    # Enable all development features for workstation
    isKubernetes = true; # Kubernetes development
    isAWS = true; # AWS development
    isTerraform = true; # Infrastructure as code
    isDocker = true; # Container development
    isMediaDev = true; # Media processing
    isDocuments = true; # Document processing
    isSystemAdmin = true; # System administration
    isMonitoring = true; # Monitoring tools
    isSecurity = true; # Security tools
    isPerformance = true; # Performance tools
    isNixDev = true; # Nix development
    isClojureDev = true; # Clojure development
  };
}
