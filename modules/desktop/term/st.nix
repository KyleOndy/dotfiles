{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.term.st;
in
{
  options.foundry.desktop.term.st = {
    enable = mkEnableOption "st term";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      st # lightweight terminal
    ];
  };
}
