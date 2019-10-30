{ pkgs, ... }:

{
  programs = {
    firefox = {
      enable = true;
      extensions = with pkgs.nur.repos.rycee.firefox-addons; [
        # todo: these are not enabled by default
        https-everywhere
        privacy-badger
        # todo: add browserpass
        # todo: add browserpass-otp
      ];
    };
    browserpass = {
      # this enabled the native application, not the firefox plugin
      enable = true;
      browsers = [ "firefox" ];
    };
  };
}
