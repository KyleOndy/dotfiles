{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.apps.discord;
in
{
  options.foundry.desktop.apps.discord = {
    enable = mkEnableOption "Discord GUI client";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      discord
    ];
  };
}
