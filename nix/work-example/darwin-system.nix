# Example nix-darwin system configuration for work environment
# This file configures system-level settings for macOS

{
  config,
  pkgs,
  lib,
  ...
}:
{
  # System identification
  networking.computerName = "work-macbook";
  networking.hostName = "work-macbook";

  # Enable TouchID for sudo
  security.pam.enableSudoTouchIdAuth = true;

  # Company VPN or network tools
  services.tailscale.enable = true;

  # System-wide packages that all users need
  environment.systemPackages = with pkgs; [
    # Version control
    git

    # Company-specific tools would go here
    # internal-cli-tool
    # company-vpn-client
  ];

  # Homebrew integration for macOS-specific apps
  homebrew = {
    enable = true;

    # Automatically update Homebrew and upgrade packages
    onActivation = {
      autoUpdate = false; # Set to true if you want auto-updates
      upgrade = false; # Set to true if you want auto-upgrades
      cleanup = "zap"; # Remove everything not listed
    };

    # GUI applications via cask
    casks = [
      "slack"
      "zoom"
      "docker"
      "visual-studio-code"
      # Add other work-required GUI apps here
    ];

    # CLI tools via brew (when not available in nixpkgs)
    brews = [
      # "some-tool-only-in-homebrew"
    ];
  };

  # macOS system preferences
  system.defaults = {
    dock = {
      autohide = true;
      show-recents = false;
      tilesize = 48;
    };

    finder = {
      AppleShowAllExtensions = true;
      FXPreferredViewStyle = "clmv"; # Column view
      ShowPathbar = true;
    };

    # Disable guest account
    loginwindow.GuestEnabled = false;

    # Trackpad settings
    trackpad = {
      Clicking = true;
      TrackpadThreeFingerDrag = true;
    };
  };

  # Enable nix-daemon
  services.nix-daemon.enable = true;

  # Nix configuration
  nix = {
    settings = {
      # Enable flakes
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Add any work-specific binary caches here
      substituters = [
        "https://cache.nixos.org"
        # "https://company-cache.example.com"
      ];

      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        # "company-cache.example.com-1:..."
      ];
    };
  };
}
