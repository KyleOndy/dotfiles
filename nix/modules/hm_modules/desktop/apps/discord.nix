{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.apps.discord;
in
{
  options.hmFoundry.desktop.apps.discord = {
    enable = mkEnableOption "Discord GUI client";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      discord
    ];
  };
}
