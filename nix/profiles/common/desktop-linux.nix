# Linux-specific desktop configuration
# Includes window managers and Linux-only desktop features

{ pkgs, lib, ... }:
with lib;
{
  imports = [
    ./desktop.nix # Base desktop configuration
  ];

  config = {
    hmFoundry = {
      desktop = {
        # Enable Linux-specific window managers
        wm = {
          kde.enable = mkDefault false; # Can be overridden in host config
        };
      };
    };

    # Linux-specific desktop packages
    home.packages = with pkgs; [
      # Linux desktop utilities
      xorg.xrandr # Display configuration
      arandr # GUI for xrandr
      pavucontrol # PulseAudio volume control
      playerctl # Media player control
    ];
  };
}
