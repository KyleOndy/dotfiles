{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.gaming.steam;
in
{
  options.hmFoundry.desktop.gaming.steam = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      steam # games # todo: I should break this out into gaming.nix
    ];
  };
}
