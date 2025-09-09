# macOS-specific desktop configuration
# Cross-platform desktop tools without Linux window managers

{ pkgs, lib, ... }:
with lib;
{
  imports = [
    ./desktop.nix # Base desktop configuration
  ];

  config = {
    # macOS-specific desktop packages
    home.packages = with pkgs; [
      # macOS desktop utilities that work well with Nix
      rectangle # Window management for macOS
      # Note: Many macOS apps are better installed via homebrew
      # in the nix-darwin configuration
    ];

    # Disable Linux-specific configurations
    hmFoundry = {
      desktop = {
        # Some desktop tools might not work well on macOS
        term = {
          # foot is Linux-only, disable it
          foot.enable = mkForce false;
        };
      };
    };
  };
}
