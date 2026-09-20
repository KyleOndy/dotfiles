{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.browsers.firefox;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # On darwin Firefox is Mozilla's signed build from the homebrew cask, not
  # nixpkgs. macOS 27 attributes ~/Library/Application Support/Firefox to
  # Team ID 43AQ936H96 (a rule baked into /usr/libexec/sandboxd) and denies
  # every other app, and nixpkgs' wrapper leaves the bundle ad-hoc signed
  # under org.nixos.firefox, so it cannot even lock its own profile.
  # home-manager still writes profiles.ini, user.js and the extensions.
  firefoxBin =
    if isDarwin then
      "/Applications/Firefox.app/Contents/MacOS/firefox"
    else
      getExe config.programs.firefox.finalPackage;

  ff-tmp = pkgs.writeShellApplication {
    name = "ff-tmp";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # Usage: ff-tmp [url...]
      # --profile sets both the profile and the local profile directory, so the
      # cache lands in the temp dir too. --new-instance, or Firefox hands the
      # url to an already running instance and ignores the profile.
      d=$(mktemp -d)
      trap 'rm -rf "$d"' EXIT
      "${firefoxBin}" --profile "$d" --new-instance "$@"
    '';
  };

  ff-scratch = pkgs.writeShellApplication {
    name = "ff-scratch";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # Usage: ff-scratch <path_of_profile> [url...]
      if [ $# -lt 1 ]; then
        echo "usage: ff-scratch <path_of_profile> [url...]" >&2
        exit 1
      fi

      mkdir -p "$1"
      prof=$(realpath "$1")
      shift
      name=$(basename "$prof")
      link="$HOME/Library/Application Support/Firefox/Profiles/$name"
      localdir="$HOME/Library/Caches/Firefox/Profiles/$name"

      if [ -e "$link" ] && [ "$(readlink "$link" || true)" != "$prof" ]; then
        echo "ff-scratch: $link exists and is not a link to $prof" >&2
        exit 1
      fi

      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp" "$link" "$localdir"' EXIT

      # Firefox only splits the disposable half of a profile out of the root when
      # the root sits under Profiles/, so launch against the link, not $prof.
      mkdir -p "$(dirname "$link")" "$(dirname "$localdir")"
      ln -sfn "$prof" "$link"
      rm -rf "$localdir"
      ln -s "$tmp" "$localdir"

      "${firefoxBin}" --profile "$link" --new-instance "$@"
    '';
  };
in
{
  options.hmFoundry.desktop.browsers.firefox = {
    enable = mkEnableOption "firefox";
  };

  config = mkIf cfg.enable {
    home.packages = [
      ff-tmp
      ff-scratch
    ];

    # Mozilla's build runs without the MOZ_LEGACY_PROFILES=1 that nixpkgs'
    # wrapper exports, so it keys the default profile on a hash of its install
    # path, finds no such entry in home-manager's profiles.ini, and creates a
    # fresh profile. Persisting that rewrites profiles.ini, a read-only store
    # symlink, and the failure surfaces as "Profile Missing". Firefox honours
    # the LegacyProfiles policy on Windows only
    # (nsToolkitProfileService::UseLegacyProfiles), so the variable goes into
    # the gui launchd domain, which is what the Dock launches from. A user
    # agent runs inside that domain; launchctl setenv from a shell or from
    # nix-darwin's activation lands in user/<uid> instead, and both last one
    # boot.
    launchd.agents.firefox-legacy-profiles = mkIf isDarwin {
      enable = true;
      config = {
        Label = "org.ondy.firefox-legacy-profiles";
        ProgramArguments = [
          "/bin/launchctl"
          "setenv"
          "MOZ_LEGACY_PROFILES"
          "1"
        ];
        RunAtLoad = true;
      };
    };

    # The mac remote client hands a running instance argv without a working
    # directory (it reads getcwd and never sends it, and the server inits
    # nsCommandLine with a null one), so a relative path cannot resolve and
    # is dropped without a word. An absolute path opens.
    # https://github.com/mozilla-firefox/firefox/blob/FIREFOX_156_0_RELEASE/toolkit/components/remote/nsMacRemoteClient.mm#L34-L35
    # https://github.com/mozilla-firefox/firefox/blob/FIREFOX_156_0_RELEASE/toolkit/components/remote/nsMacRemoteServer.mm#L57
    # A function, because /opt/homebrew/bin precedes the nix profile on PATH.
    programs.zsh.initContent = mkIf isDarwin ''
      firefox() {
        local -a args
        local a
        for a in "$@"; do
          [[ -e $a ]] && a=''${a:a}
          args+=("$a")
        done
        "${firefoxBin}" "''${args[@]}"
      }
    '';

    programs = {
      firefox = {
        enable = true;
        package = mkIf isDarwin null;
        profiles.default = {
          extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
            umatrix
          ];
          settings = {
            # Dark mode
            "ui.systemUsesDarkTheme" = 1;
            "browser.in-content.dark-mode" = true;

            # Disable Mozilla Telemetry & Data Collection
            "toolkit.telemetry.enabled" = false;
            "datareporting.healthreport.uploadEnabled" = false;
            "datareporting.policy.dataSubmissionEnabled" = false;
            "browser.ping-centre.telemetry" = false;

            # Disable Pocket & Sponsored Content
            "extensions.pocket.enabled" = false;
            "browser.newtabpage.activity-stream.showSponsored" = false;
            "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
            "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
            "browser.newtabpage.activity-stream.section.highlights.includePocket" = false;
            "browser.newtabpage.activity-stream.feeds.recommendationprovider" = false;
            "browser.newtabpage.activity-stream.discoverystream.enabled" = false;

            # WebRTC IP Leak Protection
            "media.peerconnection.ice.default_address_only" = true;
            "media.peerconnection.ice.no_host" = true;

            # Better File Picker (for Linux/KDE/GNOME)
            "widget.use-xdg-desktop-portal.file-picker" = 1;

            # Hide about:config Warning
            "browser.aboutConfig.showWarning" = false;

            # Restore Last Session
            "browser.startup.page" = 3;

            # Disable Disk Cache (use RAM only)
            "browser.cache.disk.enable" = false;
            "browser.cache.memory.enable" = true;

            # Always show bookmarks toolbar
            "browser.toolbars.bookmarks.visibility" = "always";
          };
        };
      };
    };
  };
}
