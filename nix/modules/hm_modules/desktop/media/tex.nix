{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.media.latex;
in
{
  options.hmFoundry.desktop.media.latex = {
    enable = mkEnableOption "latex";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      texlive.combined.scheme-full
    ];
  };
}
