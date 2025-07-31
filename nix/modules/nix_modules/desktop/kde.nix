{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.desktop.kde;
in
{
  options.systemFoundry.desktop.kde = {
    enable = mkEnableOption "kde";
  };

  config = mkIf cfg.enable {
    services = {
      displayManager = {
        sddm.enable = true;
        defaultSession = "plasma";
      };
      desktopManager.plasma6 = {
        enable = true;
      };
      xserver = {
        wacom.enable = true;
      };
    };
    environment.plasma6.excludePackages = with pkgs.libsForQt5; [
      plasma-browser-integration
      konsole
      oxygen
    ];
  };
}
