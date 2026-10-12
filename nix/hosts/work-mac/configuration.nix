# Work-specific darwin system configuration for work-mac.
# Shared darwin plumbing (nix settings, TouchID, homebrew scaffold, base
# system.defaults, allowUnfree) lives in nix/modules/darwin_modules/base.nix.
{
  lib,
  pkgs,
  ...
}:
let
  # Baked into the tools that call mcloud, rather than set as session
  # variables, which a shell older than the deploy (or any pane of an older
  # tmux server) never sees.
  mcloudKeyCommand = "/usr/bin/security find-generic-password -s work-secrets -a mcloud-inference -w";
in
{
  imports = [ ];

  systemFoundry.alamodeBuilder.enable = true;

  # Upstream sets the builder's maxJobs to its cores, and on trex 8 jobs
  # each taking all 8 cores thrashed 12 GiB. Four jobs at 3 GiB each, out of
  # 48 GiB and held only while the VM is up.
  nix-rosetta-builder = {
    cores = 4;
    memory = "12GiB";
  };

  # Covers the system profile only. home-manager generations live in
  # ~/.local/state/nix/profiles, which home.nix collects on its own.
  nix.gc = {
    automatic = true;
    options = "--delete-older-than 7d";
  };

  # Night Shift CLI tool
  environment.systemPackages = [
    pkgs.nightlight
    # Checks pinned mcloud model ids against the live endpoint. Wanted here in
    # particular: this host's models.json is a sops secret, so nothing in this
    # repo can spot a stale id in it.
    (pkgs.mcloud-pins.override { keyCommand = mcloudKeyCommand; })
    # Ranks the served models by AA score per reasoning effort.
    (pkgs.mcloud-rank.override {
      keyCommand = mcloudKeyCommand;
      aaKeyCommand = "/usr/bin/security find-generic-password -s work-secrets -a artificial-analysis -w";
    })
    # Grades candidate reviewer models before ALAMODE_ADVISOR_MODEL changes.
    (pkgs.advisor-eval.override { keyCommand = mcloudKeyCommand; })
    # Refuses commits and pushes naming a private model id; `leak-guard
    # install` hooks it into a clone.
    (pkgs.leak-guard.override { keyCommand = mcloudKeyCommand; })
  ];

  # The catalog and seats (alamode's modelsJsonFile and seatsFile), secrets
  # rather than store paths because the model ids in them are private. The
  # provider keys stay in the Keychain, read through work-config's
  # envFromCommands.
  sops.secrets = {
    alamode_models_json = {
      owner = "kondy";
      mode = "0400";
    };
    alamode_seats = {
      owner = "kondy";
      mode = "0400";
    };
  };

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
}
