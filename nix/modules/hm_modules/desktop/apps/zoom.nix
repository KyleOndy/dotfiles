{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.apps.zoom;
in
{
  options.hmFoundry.desktop.apps.zoom = {
    enable = mkEnableOption "zoom";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      zoom-us # pandemic life
      v4l-utils # video device management (for Elgato capture card)
      alsa-utils # audio device debugging
    ];
  };
}
