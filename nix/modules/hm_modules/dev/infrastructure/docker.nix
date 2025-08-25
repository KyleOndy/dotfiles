# Docker and container tools
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
  config = mkIf (devCfg.enable && cfg.isDocker) {
    home.packages = with pkgs; [
      docker-compose
    ];
  };
}
