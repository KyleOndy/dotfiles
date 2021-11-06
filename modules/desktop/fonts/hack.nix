{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.fonts.hack;
in
{
  options.foundry.desktop.fonts.hack = {
    enable = mkEnableOption "Hack font";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      (nerdfonts.override {
        fonts = [ "Hack" ];
      })
    ];
  };
}
