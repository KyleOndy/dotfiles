# Base darwin system configuration shared by all nix-darwin hosts.
{
  lib,
  pkgs,
  ...
}:
{
  # The Linux builder VM. launchd holds its ssh port and boots it on the
  # first build; it powers off after onDemandLingerMinutes without one, so
  # it holds no RAM between builds. A changed setting here recreates the VM,
  # store included. trex registers it with Determinate's daemon itself
  # (nix/hosts/trex/configuration.nix).
  nix-rosetta-builder = {
    onDemand = true;
    onDemandLingerMinutes = 5;
    # Sparse, so this caps the real disk the guest store can take. The
    # guest collects garbage below 5 GiB free, and over ssh-ng that GC
    # deletes a running build's own inputs. The cogsworth kernel
    # (uncompressed DWARF, ~6.5k modules) peaks near 36 GiB, so it has to
    # finish above that line.
    diskSize = "64GiB";
  };

  nix = {
    package = pkgs.nixVersions.latest;
    gc = {
      automatic = true;
      options = lib.mkDefault "--delete-older-than 35d";
    };
    optimise.automatic = true;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # root alone: a trusted client can override build-users-group and have
      # the daemon build as root. The daemon answers `trusted: false` to the
      # human too; darwin-rebuild runs under sudo, so switching is unaffected,
      # and a per-invocation --option on a restricted setting is refused.
      trusted-users = [ "root" ];
      # nix defaults this to false on darwin, which leaves a build unconfined
      # as _nixbld with the whole network. Fixed-output builds keep the
      # network either way; docs/darwin-nix-sandbox.md has what this closes
      # and what it costs (derivations carrying their own sandboxProfile do
      # not build locally, so a cache miss on one of them fails).
      sandbox = true;
      # Without it, a build with more than about 1,069 inputs fails to start:
      # macOS caps each sandbox operation's path filters at 64 KiB
      # (NixOS/nix#4119). The cost: any build can read the whole store and
      # add entries to it. docs/darwin-nix-sandbox.md has the measurements.
      extra-sandbox-paths = [ "/nix/store" ];

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
      cleanup = lib.mkDefault "zap";
    };
  };

  system.defaults = {
    # Fn twice starts Dictation. Only "Show Emoji & Symbols" binds the emoji
    # picker to Fn.
    hitoolbox.AppleFnUsageType = lib.mkDefault "Start Dictation";

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
