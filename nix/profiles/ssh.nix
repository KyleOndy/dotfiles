# SSH profile - development environment with SSH access
# This profile is suitable for remote development and server administration

{ ... }:
{
  imports = [
    ./common/base.nix
    ./common/development.nix
    ./common/ssh-hosts.nix
  ];

  hmFoundry.features = {
    isDevelopment = true;
    isDesktop = false;
    isServer = false;
    isGaming = false;

    # Enable core development features for SSH profile
    isSystemAdmin = true; # Basic system administration tools
    isNixDev = true; # Nix development tools
    isSecurity = true; # Security tools for remote access
  };
}
