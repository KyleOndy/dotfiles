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
    };
    environment.plasma6.excludePackages = with pkgs.kdePackages; [
      plasma-browser-integration
      konsole
      oxygen
    ];

    environment.systemPackages = with pkgs; [
      kdePackages.partitionmanager
    ];
  };
}
