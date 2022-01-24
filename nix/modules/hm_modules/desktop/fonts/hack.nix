{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.fonts.hack;
in
{
  options.hmFoundry.desktop.fonts.hack = {
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
