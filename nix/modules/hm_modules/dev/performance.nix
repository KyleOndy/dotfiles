# Performance analysis and optimization tools
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
  config = mkIf (devCfg.enable && cfg.isPerformance) {
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
