# Base darwin system configuration shared by all nix-darwin hosts.
{
  lib,
  pkgs,
  ...
}:
{
  nix.linux-builder.enable = true;

  nix = {
    package = pkgs.nixVersions.latest;
    optimise.automatic = true;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@admin"
      ];
    };
    nixPath = [ "nixpkgs=${pkgs.path}" ];
  };

  # Enable TouchID for sudo (nice quality of life improvement)
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault true;
  security.pam.services.sudo_local.reattach = lib.mkDefault true;

  # Homebrew integration for GUI applications and tools not in nixpkgs.
  # casks/taps/brews are intentionally left out here — those are host-specific.
  homebrew = {
    enable = lib.mkDefault true;
    onActivation = {
      autoUpdate = lib.mkDefault false;
      upgrade = lib.mkDefault false;
      cleanup = lib.mkDefault "zap"; # Remove packages not in config
    };
  };

  system.defaults = {
    # Disable Globe/Fn key emoji picker
    hitoolbox.AppleFnUsageType = lib.mkDefault "Do Nothing";

    dock = {
      autohide = lib.mkDefault true;
      show-recents = lib.mkDefault false;
      tilesize = lib.mkDefault 48;
      mru-spaces = lib.mkDefault false; # Don't rearrange spaces
      autohide-delay = lib.mkDefault 0.0; # No delay before showing
      autohide-time-modifier = lib.mkDefault 0.3; # Faster show/hide animation
      expose-animation-duration = lib.mkDefault 0.1; # Faster Mission Control
      showhidden = lib.mkDefault true; # Dim hidden apps
      # persistent-apps is host-specific (hardcodes a user's home path)
    };

    finder = {
      AppleShowAllExtensions = lib.mkDefault true;
      FXPreferredViewStyle = lib.mkDefault "clmv"; # Column view
      ShowPathbar = lib.mkDefault true;
      ShowStatusBar = lib.mkDefault true;
      AppleShowAllFiles = lib.mkDefault true; # Show hidden files (dotfiles visible)
      _FXShowPosixPathInTitle = lib.mkDefault true; # Full path in Finder title bar
      FXEnableExtensionChangeWarning = lib.mkDefault false;
      FXDefaultSearchScope = lib.mkDefault "SCcf"; # Search current folder by default
    };

    trackpad.Clicking = lib.mkDefault true; # Tap to click

    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      "com.apple.swipescrolldirection" = false; # Traditional scrolling (not natural)

      # Fast key repeat (essential for vim)
      InitialKeyRepeat = lib.mkDefault 15; # Default 25, lower = faster
      KeyRepeat = lib.mkDefault 2; # Default 6, lower = faster

      # Disable press-and-hold for accents (enable key repeat)
      ApplePressAndHoldEnabled = lib.mkDefault false;

      # Disable auto-correct annoyances
      NSAutomaticCapitalizationEnabled = lib.mkDefault false;
      NSAutomaticDashSubstitutionEnabled = lib.mkDefault false;
      NSAutomaticPeriodSubstitutionEnabled = lib.mkDefault false;
      NSAutomaticQuoteSubstitutionEnabled = lib.mkDefault false;
      NSAutomaticSpellingCorrectionEnabled = lib.mkDefault false;

      # Full keyboard access (tab through all controls)
      AppleKeyboardUIMode = lib.mkDefault 3;

      # Always show expanded save/print dialogs
      NSNavPanelExpandedStateForSaveMode = lib.mkDefault true;
      NSNavPanelExpandedStateForSaveMode2 = lib.mkDefault true;
      PMPrintingExpandedStateForPrint = lib.mkDefault true;
      PMPrintingExpandedStateForPrint2 = lib.mkDefault true;

      # Save to disk by default, not iCloud
      NSDocumentSaveNewDocumentsToCloud = lib.mkDefault false;
    };

    CustomUserPreferences = {
      # Control Center menu bar items (always show)
      "com.apple.controlcenter" = {
        Sound = 18;
        Battery = 18;
        Bluetooth = 18;
        WiFi = 18;
        Display = 18;
      };

      "com.apple.symbolichotkeys".AppleSymbolicHotKeys = {
        # Disable input source switching so tmux prefix (Ctrl+Space) works
        "60".enabled = false; # Select previous input source (Ctrl+Space)
        "61".enabled = false; # Select next source in input menu (Ctrl+Option+Space)
      };
    };
  };

  # Many personal/dev tools require this
  nixpkgs.config.allowUnfree = true;
}
