# Security and secrets management tools
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
  config = mkIf (devCfg.enable && cfg.isSecurity) {
    home.packages = with pkgs; [
      age
      sops
      openvpn
      zbar
    ];
  };
}
