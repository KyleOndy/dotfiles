# SSH profile - development environment with SSH access
# This profile is suitable for remote development and server administration

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/ssh-hosts.nix
  ];

  # Enable core development features for SSH profile
  hmFoundry.dev = {
    sysadmin.enable = true;
    nixTools.enable = true;
    security.enable = true;
  };
}
