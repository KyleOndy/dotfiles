{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.gaming.steam;
in
{
  options.foundry.desktop.gaming.steam = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      steam # games # todo: I should break this out into gaming.nix
    ];
  };
}
