{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.apps.zoom;
in
{
  options.hmFoundry.desktop.apps.zoom = {
    enable = mkEnableOption "zoom";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      zoom-us # pandemic life
    ];
  };
}
