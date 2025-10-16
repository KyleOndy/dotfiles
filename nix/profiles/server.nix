# Server profile - headless systems accessed via SSH
# Full development environment without GUI applications
# Suitable for remote servers, VMs, and terminal-only environments

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/ssh-hosts.nix
  ];

  # Enable full development features for servers
  # Same tools as desktop systems, just without GUI
  hmFoundry.dev = {
    kubernetes.enable = true;
    aws.enable = true;
    terraform.enable = true;
    docker.enable = true;
    sysadmin.enable = true;
    monitoring.enable = true;
    security.enable = true;
    performance.enable = true;
    nixTools.enable = true;
  };
}
