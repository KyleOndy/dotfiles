# Media processing and content creation tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.features;
  devCfg = config.hmFoundry.dev;
in
{
  config = mkIf (devCfg.enable && cfg.isMediaDev) {
    home.packages = with pkgs; [
      ffmpeg
      exiftool
      diff-pdf
      master.yt-dlp
    ];
  };
}
