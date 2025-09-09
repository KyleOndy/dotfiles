{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.term.st;
in
{
  options.hmFoundry.desktop.term.st = {
    enable = mkEnableOption "st term";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      st # lightweight terminal
    ];
  };
}
