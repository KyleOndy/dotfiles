# Desktop profile - systems with GUI and physical interaction
# Full development environment with desktop applications
# Suitable for workstations, laptops, and systems with monitors/keyboards

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/desktop.nix
    ./common/ssh-hosts.nix
  ];

  # Enable all development features for desktop systems
  # Includes GUI-related tools like media and document processing
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
