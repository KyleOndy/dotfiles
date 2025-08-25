# System administration and monitoring tools
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
  config = mkIf (devCfg.enable && cfg.isSystemAdmin) {
    home.packages = with pkgs; [
      htop
      lsof
      nettools
      dnsutils
      nmap
      mosh
    ];
  };
}
