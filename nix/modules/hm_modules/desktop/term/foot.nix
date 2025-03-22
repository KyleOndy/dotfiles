{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.term.foot;
in
{
  options.hmFoundry.desktop.term.foot = {
    enable = mkEnableOption "foot";
    descrption = "
    A fast, lightweight and minimalistic Wayland terminal emulator

    https://codeberg.org/dnkl/foot
    ";
  };

  config = mkIf cfg.enable {
    programs.foot = {
      enable = true;
      settings = {
        main = {
          font = "BerkeleyMono:size=7";
          dpi-aware = "yes";
        };
        cursor = {
          blink = "yes";
        };
        mouse = {
          hide-when-typing = "yes";
        };
      };
    };
  };
}
