# Kiosk profile - minimal configuration for single-purpose displays
# No development tools, just enough for the kiosk to function and SSH management

{ ... }:
{
  imports = [
    ./common/base.nix
    # No development.nix - kiosk doesn't need dev tools
    # No desktop.nix - kiosk manages its own display via cage
    # No ssh-hosts.nix - kiosk doesn't need SSH host configs
  ];

  # Minimal hmFoundry configuration
  # Most features disabled for kiosk - only essential tools
}
