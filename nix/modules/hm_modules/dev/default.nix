# Development module hub - imports all development submodules
# Package installation is now handled by feature-flag-aware submodules

{ lib, config, ... }:
with lib;
{
  imports = [
    ./core.nix
    ./cloud/aws.nix
    ./cloud/k8s.nix
    ./terraform.nix
    ./infrastructure/docker.nix
    ./media.nix
    ./documents.nix
    ./sysadmin.nix
    ./monitoring.nix
    ./security.nix
    ./performance.nix
    ./nix-tools.nix
    ./tools.nix
    ./rust.nix
  ];

  options.hmFoundry.dev = {
    enable = mkEnableOption "General development utilities and configuration";
  };
}
