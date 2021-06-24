{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.browsers.firefox;
in
{
  options.foundry.desktop.browsers.firefox = {
    enable = mkEnableOption "firefox";
  };

  config = mkIf cfg.enable {
    programs = {
      firefox = {
        enable = true;
        extensions = with pkgs.nur.repos.rycee.firefox-addons; [
          # todo: these are not enabled by default
          browserpass
          https-everywhere
          multi-account-containers
          privacy-badger
          umatrix
          vim-vixen
        ];
      };
      browserpass = {
        # this enabled the native application, not the firefox plugin
        enable = true;
        browsers = [ "firefox" ];
      };
    };
  };
}
