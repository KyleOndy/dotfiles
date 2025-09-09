{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.media.music;
in
{
  options.hmFoundry.desktop.media.music = {
    enable = mkEnableOption "music streaming and playback tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      ncspot # cursors spotify client
    ];
  };
}
