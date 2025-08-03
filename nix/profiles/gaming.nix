# Gaming profile - extends workstation with gaming support
# Includes all development and desktop features plus gaming

{ ... }:
{
  imports = [ ./workstation.nix ];

  hmFoundry.features = {
    isDevelopment = true;
    isDesktop = true;
    isServer = false;
    isGaming = true;
  };

  # Gaming is already enabled via desktop.nix (steam.enable = true)
  # Additional gaming-specific configuration can be added here
}
