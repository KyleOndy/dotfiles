{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.browsers.firefox;
in
{
  options.hmFoundry.desktop.browsers.firefox = {
    enable = mkEnableOption "firefox";
  };

  config = mkIf cfg.enable {
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
