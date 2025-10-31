# Development module hub - imports all development submodules
# Package installation is now handled by feature-flag-aware submodules

{ lib, config, ... }:
with lib;
{
  imports = [
    ./cloud/aws.nix
    ./cloud/k8s.nix
    ./core.nix
    ./documents.nix
    ./infrastructure/docker.nix
    ./java.nix
    ./media.nix
    ./monitoring.nix
    ./nix-tools.nix
    ./performance.nix
    ./rust.nix
    ./security.nix
    ./sysadmin.nix
    ./terraform.nix
    ./tools.nix
  ];

  options.hmFoundry.dev = {
    enable = mkEnableOption "General development utilities and configuration";
  };
}
