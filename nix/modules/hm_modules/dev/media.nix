# Media processing and content creation tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.media;
in
{
  options.hmFoundry.dev.media = {
    enable = mkEnableOption "Media processing and content creation tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      ffmpeg
      exiftool
      diff-pdf
      master.yt-dlp
    ];
  };
}
