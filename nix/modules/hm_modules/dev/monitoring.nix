# Advanced monitoring and diagnostic tools
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
  config = mkIf (devCfg.enable && cfg.isMonitoring) {
    home.packages = with pkgs; [
      glances
      viddy
      watch
      pv
    ];
  };
}
