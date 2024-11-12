{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.desktop.kde;
in
{
  options.systemFoundry.desktop.kde = {
    enable = mkEnableOption "kde";
  };

  config = mkIf cfg.enable {
    services = {
      displayManager = {
        sddm.enable = true;
        defaultSession = "plasmawayland";
      };
      xserver = {
        desktopManager.plasma5 = {
          enable = true;
        };
        wacom.enable = true;
      };
    };
    environment.plasma5.excludePackages = with pkgs.libsForQt5; [
      plasma-browser-integration
      konsole
      oxygen
    ];
  };
}
