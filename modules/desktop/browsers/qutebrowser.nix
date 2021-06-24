{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.browsers.qutebrowser;
in
{
  options.foundry.desktop.browsers.qutebrowser = {
    enable = mkEnableOption "todo";
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
