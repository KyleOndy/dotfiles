{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.browsers.qutebrowser;
in
{
  options.hmFoundry.desktop.browsers.qutebrowser = {
    enable = mkEnableOption "qutebrowser";
  };

  config = mkIf cfg.enable {
    programs = {
      qutebrowser = {
        enable = true;
        searchEngines = {
          DEFAULT = "https://duckduckgo.com/?q={}";
        };
      };
    };
  };
}
