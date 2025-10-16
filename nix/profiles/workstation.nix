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

  # Enable all development features for workstation
  hmFoundry.dev = {
    kubernetes.enable = true;
    aws.enable = true;
    terraform.enable = true;
    docker.enable = true;
    media.enable = true;
    documents.enable = true;
    sysadmin.enable = true;
    monitoring.enable = true;
    security.enable = true;
    performance.enable = true;
    nixTools.enable = true;
  };
}
