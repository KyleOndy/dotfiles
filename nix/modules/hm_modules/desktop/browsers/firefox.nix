{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.browsers.firefox;

  firefoxBin =
    if pkgs.stdenv.hostPlatform.isDarwin then
      # The darwin build ships an .app bundle and no bin/ directory.
      "${config.programs.firefox.finalPackage}/Applications/Firefox.app/Contents/MacOS/firefox"
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
in
{
  options.hmFoundry.desktop.browsers.firefox = {
    enable = mkEnableOption "firefox";
  };

  config = mkIf cfg.enable {
    home.packages = [ ff-tmp ];

    programs = {
      firefox = {
        enable = true;
        profiles.default = {
          extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
            browserpass
            multi-account-containers
            privacy-badger
            umatrix
            vim-vixen
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
      browserpass = {
        # this enabled the native application, not the firefox plugin
        enable = true;
        browsers = [ "firefox" ];
      };
    };
  };
}
