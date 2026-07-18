# Work-specific darwin system configuration for work-mac.
# Shared darwin plumbing (nix settings, TouchID, homebrew scaffold, base
# system.defaults, allowUnfree) lives in nix/modules/darwin_modules/base.nix.
{
  lib,
  pkgs,
  ...
}:
{
  imports = [ ];

  # Night Shift CLI tool
  environment.systemPackages = [ pkgs.nightlight ];

  # Homebrew integration for GUI applications and tools not in nixpkgs
  homebrew = {
    # Default casks (can be overridden with lib.mkForce in work.nix)
    casks = lib.mkDefault [
      "cursor"
      "hammerspoon"
      "karabiner-elements"
      "linear"
      "pocket-casts"
      "shottr"
      "spotify"
    ];

    # Homebrew taps for additional formula sources
    taps = [
      "chipmk/tap"
      "datadog-labs/pack"
    ];

    # Default brews (can be overridden with lib.mkForce in work.nix)
    brews = [
      "go"
      "golangci-lint"
      "chipmk/tap/docker-mac-net-connect"
      "datadog-labs/pack/pup"
    ]; # Use Homebrew for CGO compatibility and Go version sync
  };

  system = {
    # System version (managed by nix-darwin) - snapshot from when work-mac
    # was created, per-host, never bumped in lockstep with other hosts.
    stateVersion = 5;

    defaults = {
      dock = {
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

      # Disable macOS screenshot shortcuts so Shottr can intercept them
      CustomUserPreferences."com.apple.symbolichotkeys".AppleSymbolicHotKeys = {
        "28".enabled = false; # Cmd+Shift+3 (full screen to file)
        "29".enabled = false; # Ctrl+Cmd+Shift+3 (full screen to clipboard)
        "30".enabled = false; # Cmd+Shift+4 (selection to file)
        "31".enabled = false; # Ctrl+Cmd+Shift+4 (selection to clipboard)
        "184".enabled = false; # Cmd+Shift+5 (screenshot options panel)
        "164".enabled = false; # Ctrl+Cmd+Space (Emoji & Symbols / Character Viewer)
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

  # DNS resolution for forge dev cluster
  # More-specific entries take priority; catch-all handles *.forge.test
  services.dnsmasq = {
    enable = true;
    addresses = {
      "forge-1.forge.test" = "172.20.201.1";
      "forge-2.forge.test" = "172.20.202.1";
      "forge.test" = "172.20.200.1";
    };
  };
}
