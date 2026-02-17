# Base darwin system configuration for work macOS environments
# This provides sensible defaults that can be extended via work.nix in work forks
{
  lib,
  pkgs,
  ...
}:
{
  # Conditional import of work-specific overrides
  # Work forks should create work.nix in this directory with company-specific config
  imports = [ ] ++ lib.optional (builtins.pathExists ./work.nix) ./work.nix;

  # Nix configuration
  nix = {
    package = pkgs.nixVersions.latest;
    optimise.automatic = true;
    settings = {
      # Enable flakes and new nix commands
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Trusted users can use additional nix features
      trusted-users = [
        "root"
        "@admin"
      ];
    };

    # Use nixpkgs from registry for consistency
    nixPath = [ "nixpkgs=${pkgs.path}" ];
  };

  # Enable TouchID for sudo (nice quality of life improvement)
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault true;

  # Night Shift CLI tool
  environment.systemPackages = [ pkgs.nightlight ];

  # Homebrew integration for GUI applications and tools not in nixpkgs
  homebrew = {
    enable = lib.mkDefault true;

    # Behavior during activation
    onActivation = {
      autoUpdate = lib.mkDefault false;
      upgrade = lib.mkDefault false;
      cleanup = lib.mkDefault "zap"; # Remove packages not in config
    };

    # Default casks (can be overridden with lib.mkForce in work.nix)
    casks = lib.mkDefault [
      "hammerspoon"
      "karabiner-elements"
      "linear-linear"
      "pocket-casts"
      "shottr"
      "spotify"
    ];

    # Default brews (can be overridden with lib.mkForce in work.nix)
    brews = [ "go" ]; # Use Homebrew Go for CGO compatibility
  };

  # macOS system preferences
  system = {
    # Primary user for homebrew and system defaults
    primaryUser = "kondy";

    # System version (managed by nix-darwin)
    stateVersion = 5;

    defaults = {
      # Disable Globe/Fn key emoji picker
      hitoolbox.AppleFnUsageType = lib.mkDefault "Do Nothing";
      # Dock preferences
      dock = {
        autohide = lib.mkDefault true;
        show-recents = lib.mkDefault false;
        tilesize = lib.mkDefault 48;
        mru-spaces = lib.mkDefault false; # Don't rearrange spaces

        # Faster dock animations
        autohide-delay = lib.mkDefault 0.0; # No delay before showing
        autohide-time-modifier = lib.mkDefault 0.3; # Faster show/hide animation

        # Faster Mission Control
        expose-animation-duration = lib.mkDefault 0.1;

        # Dim hidden apps
        showhidden = lib.mkDefault true;

        # Minimal dock - only essentials
        persistent-apps = lib.mkDefault [
          "/System/Library/CoreServices/Finder.app"
          "/Users/kondy/Applications/Home Manager Apps/Firefox.app"
          "/Users/kondy/Applications/Home Manager Apps/Alacritty.app"
          "/Applications/Linear.app"
          "/Applications/Notion.app"
          "/Applications/Pocket Casts.app"
          "/Applications/Spotify.app"
          "/Applications/zoom.us.app"
        ];
      };

      # Finder preferences
      finder = {
        AppleShowAllExtensions = lib.mkDefault true;
        FXPreferredViewStyle = lib.mkDefault "clmv"; # Column view
        ShowPathbar = lib.mkDefault true;
        ShowStatusBar = lib.mkDefault true;

        # Show hidden files (dotfiles visible)
        AppleShowAllFiles = lib.mkDefault true;

        # Full path in Finder title bar
        _FXShowPosixPathInTitle = lib.mkDefault true;

        # Disable extension change warning
        FXEnableExtensionChangeWarning = lib.mkDefault false;

        # Search current folder by default
        FXDefaultSearchScope = lib.mkDefault "SCcf";
      };

      # Trackpad settings
      trackpad = {
        Clicking = lib.mkDefault true; # Tap to click
      };

      # Global system preferences
      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark"; # Use dark mode
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

        # Always show expanded save dialogs
        NSNavPanelExpandedStateForSaveMode = lib.mkDefault true;
        NSNavPanelExpandedStateForSaveMode2 = lib.mkDefault true;

        # Always show expanded print dialogs
        PMPrintingExpandedStateForPrint = lib.mkDefault true;
        PMPrintingExpandedStateForPrint2 = lib.mkDefault true;

        # Save to disk by default, not iCloud
        NSDocumentSaveNewDocumentsToCloud = lib.mkDefault false;
      };

      # Custom system preferences
      CustomUserPreferences = {
        # Control Center menu bar items
        "com.apple.controlcenter" = {
          Sound = 18; # Always show in menu bar (18 = show, 24 = Control Center only, 8 = hide)
          Battery = 18; # Always show battery icon
          Bluetooth = 18; # Always show Bluetooth icon
          WiFi = 18; # Always show WiFi icon
        };

        # Disable macOS screenshot shortcuts so Shottr can intercept them
        "com.apple.symbolichotkeys" = {
          AppleSymbolicHotKeys = {
            # Disable input source switching so tmux prefix (Ctrl+Space) works
            "60" = {
              enabled = false;
            }; # Select previous input source (Ctrl+Space)
            "61" = {
              enabled = false;
            }; # Select next source in input menu (Ctrl+Option+Space)

            "28" = {
              enabled = false;
            }; # Cmd+Shift+3 (full screen to file)
            "29" = {
              enabled = false;
            }; # Ctrl+Cmd+Shift+3 (full screen to clipboard)
            "30" = {
              enabled = false;
            }; # Cmd+Shift+4 (selection to file)
            "31" = {
              enabled = false;
            }; # Ctrl+Cmd+Shift+4 (selection to clipboard)
            "184" = {
              enabled = false;
            }; # Cmd+Shift+5 (screenshot options panel)
            "164" = {
              enabled = false;
            }; # Ctrl+Cmd+Space (Emoji & Symbols / Character Viewer)
          };
        };
      };
    };
  };

  # Configure Night Shift at login
  launchd.agents.nightshift = {
    serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          ${pkgs.nightlight}/bin/nightlight schedule start
          ${pkgs.nightlight}/bin/nightlight temp 90
        ''
      ];
      RunAtLoad = true;
    };
  };

  # Add screenshots directory to Finder sidebar
  launchd.agents.finder-sidebar = {
    serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          # Create screenshots directory if it doesn't exist
          mkdir -p ~/screenshots

          # Add to Finder sidebar (idempotent - won't duplicate if already exists)
          /usr/bin/sfltool add-item com.apple.LSSharedFileList.FavoriteItems file:///Users/kondy/screenshots
        ''
      ];
      RunAtLoad = true;
    };
  };

  # Allow unfree packages (many work tools require this)
  nixpkgs.config.allowUnfree = true;
}
