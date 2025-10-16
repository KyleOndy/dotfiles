# Gaming profile - extends workstation with gaming support
# Includes all development and desktop features plus gaming

{ ... }:
{
  imports = [ ./workstation.nix ];

  # Gaming is already enabled via desktop.nix (steam.enable = true)
  # Additional gaming-specific configuration can be added here
}
