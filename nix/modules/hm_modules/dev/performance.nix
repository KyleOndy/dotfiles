# Performance analysis and optimization tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.performance;
in
{
  options.hmFoundry.dev.performance = {
    enable = mkEnableOption "Performance analysis and optimization tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      parallel
      mbuffer
      lz4
      lzop
      pixz
      xz
    ];
  };
}
