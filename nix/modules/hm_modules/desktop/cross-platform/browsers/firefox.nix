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
        profiles.default.extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
          browserpass
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
