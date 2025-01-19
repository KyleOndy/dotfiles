{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.gaming.steam;
in
{
  options.hmFoundry.desktop.gaming.steam = {
    enable = mkEnableOption "steam";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      steam # games
    ];
  };
}
