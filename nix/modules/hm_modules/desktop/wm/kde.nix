#
# To generate a json of current config run the following command
#   nix run github:pjones/plasma-manager
#
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.wm.kde;
in
{
  options.hmFoundry.desktop.wm.kde = {
    enable = mkEnableOption "kde";
  };

  config = mkIf cfg.enable {
    programs.plasma = {
      enable = true;

      configFile = {
        "baloofilerc"."Basic Settings"."Indexing-Enabled".value = false;
        "kwinrc"."NightColor"."Active".value = true;
        "kwinrc"."NightColor"."NightTemperature".value = 2400;
      };
    };
  };
}
