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
  environment.systemPackages = [
    pkgs.nightlight
    # Checks pinned mcloud model ids against the live endpoint. Wanted here in
    # particular: this host's models.json comes from work-config, so nothing in
    # this repo can spot a stale id in it.
    pkgs.mcloud-pins
  ];

  # Homebrew integration for GUI applications and tools not in nixpkgs
  homebrew = {
    # Default casks (can be overridden with lib.mkForce in work.nix)
    casks = lib.mkDefault [
      "alt-tab"
      "cursor"
      "firefox" # Mozilla's signed build, see hmFoundry.desktop.browsers.firefox
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
    ]; # Use Homebrew for CGO compatibility and Go version sync

    # Homebrew 6 will not load a third-party tap's formula unless it is
    # trusted, and `brew bundle cleanup --force` replaces the trust store with
    # exactly what the Brewfile declares, so a hand-run `brew trust` survives
    # only until the next activation. nix-darwin's `homebrew.brews` cannot emit
    # the `trusted:` option, hence raw Brewfile lines.
    extraConfig = ''
      brew "chipmk/tap/docker-mac-net-connect", trusted: true
      brew "datadog-labs/pack/pup", trusted: true
    '';
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
          "/Applications/Firefox.app"
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

  # Finder sidebar favourites, see nix/modules/darwin_modules/finder-sidebar.nix
  systemFoundry.finderSidebar.folders = [
    "/Users/kondy/screenshots"
  ];

  # DNS resolution for forge dev cluster. Names must match the clusters in
  # nix/pkgs/forge/forge.yaml.
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
