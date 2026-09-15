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

      # pi and sandbox-runtime come from the llm-agents input, which Hydra
      # never sees; numtide's CI is the only thing that prebuilds them.
      extra-substituters = [ "https://cache.numtide.com" ];
      extra-trusted-public-keys = [
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      ];
    };
    nixPath = [ "nixpkgs=${pkgs.path}" ];
  };

  # Enable TouchID for sudo (nice quality of life improvement)
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault true;
  security.pam.services.sudo_local.reattach = lib.mkDefault true;

  # Homebrew integration for GUI applications and tools not in nixpkgs.
  # casks/taps/brews are intentionally left out here, those are host-specific.
  homebrew = {
    enable = lib.mkDefault true;
    onActivation = {
      # Refresh cask metadata on activation so installs don't fail on a
      # stale version whose upstream asset was pulled (brew bundle otherwise
      # runs with HOMEBREW_NO_AUTO_UPDATE=1).
      autoUpdate = lib.mkDefault true;
      upgrade = lib.mkDefault false;

      # "none", not "zap": on the pinned nix-darwin-25.11
      # (LnL7/nix-darwin@ebec37af) any other value makes nix-darwin prepend a
      # bare `--cleanup`, which Homebrew 7.x rejects ("Calling the
      # `--cleanup` switch is disabled! There is no replacement."). Fixed
      # upstream by LnL7/nix-darwin@bb9c29c19 but not yet on 25.11;
      # extraFlags below reproduces zap-cleanup meanwhile. Revert both once
      # 25.11 catches up.
      cleanup = lib.mkDefault "none";

      # --force-cleanup, not --force: brew bundle reads --force as
      # --overwrite for the installs themselves.
      extraFlags = lib.mkDefault [
        "--zap"
        "--force-cleanup"
      ];
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

    # Drop the Tags section from the Finder sidebar. nix-darwin has no option
    # for either key. An empty FavoriteTagNames unchecks every tag in Finder
    # Settings > Tags, ShowRecentTags = false kills the "Recent Tags" row, and
    # with nothing left to list Finder stops drawing the Tags header.
    CustomUserPreferences."com.apple.finder" = {
      FavoriteTagNames = [ ];
      ShowRecentTags = false;
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
