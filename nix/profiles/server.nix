# Server profile - headless systems reached over SSH.
# The full development environment with no GUI layer. tiger imports this
# directly; desktop.nix is this profile plus the GUI on top.

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/ssh-hosts.nix
  ];

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
